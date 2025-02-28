local health = vim.health or require "health"
local _ = require "mason-core.functional"
local a = require "mason-core.async"
local async_uv = require "mason-core.async.uv"
local github_client = require "mason-core.managers.github.client"
local platform = require "mason-core.platform"
local registry_sources = require "mason-registry.sources"
local spawn = require "mason-core.spawn"

local M = {}

---@alias HealthCheckResult
---| '"success"'
---| '"version-mismatch"'
---| '"parse-error"'
---| '"not-available"'

---@class HealthCheck
---@field public result HealthCheckResult
---@field public version string?
---@field public relaxed boolean?
---@field public reason string?
---@field public name string
local HealthCheck = {}
HealthCheck.__index = HealthCheck

function HealthCheck.new(props)
    local self = setmetatable(props, HealthCheck)
    return self
end

function HealthCheck:get_version()
    if self.result == "success" and not self.version or self.version == "" then
        -- Some checks (bourne shell for instance) don't produce any output, so we default to just "Ok"
        return "Ok"
    end
    return self.version
end

function HealthCheck:get_health_report_level()
    return ({
        ["success"] = "report_ok",
        ["parse-error"] = "report_warn",
        ["version-mismatch"] = self.relaxed and "report_warn" or "report_error",
        ["not-available"] = self.relaxed and "report_warn" or "report_error",
    })[self.result]
end

function HealthCheck:__tostring()
    if self.result == "success" then
        return ("**%s**: `%s`"):format(self.name, self:get_version())
    elseif self.result == "version-mismatch" then
        return ("**%s**: unsupported version `%s`. %s"):format(self.name, self:get_version(), self.reason)
    elseif self.result == "parse-error" then
        return ("**%s**: failed to parse version"):format(self.name)
    elseif self.result == "not-available" then
        return ("**%s**: not available"):format(self.name)
    end
end

---@param callback fun(result: HealthCheck)
local function mk_healthcheck(callback)
    ---@param opts {cmd:string, args:string[], name: string, use_stderr: boolean?, version_check: fun(version: string): string?, relaxed: boolean?}
    return function(opts)
        local parse_version = _.compose(
            _.head,
            _.filter(_.complement(_.matches "^%s*$")),
            _.split "\n",
            _.if_else(_.always(opts.use_stderr), _.prop "stderr", _.prop "stdout")
        )

        ---@async
        return function()
            local healthcheck_result = spawn
                [opts.cmd]({
                    opts.args,
                    on_spawn = a.scope(function(_, stdio)
                        local stdin = stdio[1]
                        -- some processes (`sh` for example) will endlessly read from stdin, so we close it immediately
                        async_uv.shutdown(stdin)
                        async_uv.close(stdin)
                    end),
                })
                :map(parse_version)
                :map(function(version)
                    if opts.version_check then
                        local ok, version_check = pcall(opts.version_check, version)
                        if ok and version_check then
                            return HealthCheck.new {
                                result = "version-mismatch",
                                reason = version_check,
                                version = version,
                                name = opts.name,
                                relaxed = opts.relaxed,
                            }
                        elseif not ok then
                            return HealthCheck.new {
                                result = "parse-error",
                                version = "N/A",
                                name = opts.name,
                                relaxed = opts.relaxed,
                            }
                        end
                    end

                    return HealthCheck.new {
                        result = "success",
                        version = version,
                        name = opts.name,
                        relaxed = opts.relaxed,
                    }
                end)
                :get_or_else(HealthCheck.new {
                    result = "not-available",
                    version = nil,
                    name = opts.name,
                    relaxed = opts.relaxed,
                })

            callback(healthcheck_result)
        end
    end
end

function M.check()
    health.report_start "mason.nvim report"
    if vim.fn.has "nvim-0.7.0" == 1 then
        health.report_ok "neovim version >= 0.7.0"
    else
        health.report_error "neovim version < 0.7.0"
    end

    local completed = 0

    local check = mk_healthcheck(vim.schedule_wrap(
        ---@param healthcheck HealthCheck
        function(healthcheck)
            completed = completed + 1
            health[healthcheck:get_health_report_level()](tostring(healthcheck))
        end
    ))

    for source in registry_sources.iter { include_uninstalled = true } do
        if source:is_installed() then
            health.report_ok(("Registry `%s` is installed."):format(source:get_display_name()))
        else
            health.report_error(
                ("Registry `%s` is not installed. Run :MasonUpdate to install."):format(source:get_display_name())
            )
        end
    end

    local checks = {
        check {
            name = "unzip",
            cmd = "unzip",
            args = { "-v" },
        },
        check {
            cmd = "go",
            args = { "version" },
            name = "Go",
            relaxed = true,
            version_check = function(version)
                -- Parses output such as "go version go1.17.3 darwin/arm64" into major, minor, patch components
                local _, _, major, minor = version:find "go(%d+)%.(%d+)"
                -- Due to https://go.dev/doc/go-get-install-deprecation
                if not (tonumber(major) >= 1 and tonumber(minor) >= 17) then
                    return "Go version must be >= 1.17."
                end
            end,
        },
        check {
            cmd = "cargo",
            args = { "--version" },
            name = "cargo",
            relaxed = true,
            version_check = function(version)
                local _, _, major, minor = version:find "(%d+)%.(%d+)%.(%d+)"
                if (tonumber(major) <= 1) and (tonumber(minor) < 60) then
                    return "Some cargo installations require Rust >= 1.60.0."
                end
            end,
        },
        check {
            cmd = "luarocks",
            args = { "--version" },
            name = "luarocks",
            relaxed = true,
            version_check = function(version)
                local _, _, major = version:find "(%d+)%.(%d)%.(%d)"
                if not (tonumber(major) >= 3) then
                    -- Because of usage of "--dev" flag
                    return "Luarocks version must be >= 3.0.0."
                end
            end,
        },
        check { cmd = "ruby", args = { "--version" }, name = "Ruby", relaxed = true },
        check { cmd = "gem", args = { "--version" }, name = "RubyGem", relaxed = true },
        check { cmd = "composer", args = { "--version" }, name = "Composer", relaxed = true },
        check { cmd = "php", args = { "--version" }, name = "PHP", relaxed = true },
        check {
            cmd = "npm",
            args = { "--version" },
            name = "npm",
            version_check = function(version)
                -- Parses output such as "8.1.2" into major, minor, patch components
                local _, _, major = version:find "(%d+)%.(%d+)%.(%d+)"
                -- Based off of general observations of feature parity
                if tonumber(major) < 6 then
                    return "npm version must be >= 6"
                end
            end,
        },
        check {
            cmd = "node",
            args = { "--version" },
            name = "node",
            version_check = function(version)
                -- Parses output such as "v16.3.1" into major, minor, patch
                local _, _, major = version:find "v(%d+)%.(%d+)%.(%d+)"
                if tonumber(major) < 14 then
                    return "Node version must be >= 14"
                end
            end,
        },
        check { cmd = "python3", args = { "--version" }, name = "python3", relaxed = true },
        check { cmd = "python3", args = { "-m", "pip", "--version" }, name = "pip3", relaxed = true },
        check { cmd = "javac", args = { "-version" }, name = "javac", relaxed = true },
        check { cmd = "java", args = { "-version" }, name = "java", use_stderr = true, relaxed = true },
        check { cmd = "julia", args = { "--version" }, name = "julia", relaxed = true },
        check { cmd = "wget", args = { "--version" }, name = "wget" },
        -- wget is used interchangeably with curl, but with higher priority, so we mark curl as relaxed
        check { cmd = "curl", args = { "--version" }, name = "curl", relaxed = true },
        check {
            cmd = "gzip",
            args = { "--version" },
            name = "gzip",
            use_stderr = platform.is.mac, -- Apple gzip prints version string to stderr
            relaxed = platform.is.win,
        },
        check { cmd = "tar", args = { "--version" }, name = "tar" },
        check {
            cmd = "pwsh",
            args = {
                "-NoProfile",
                "-Command",
                [[$PSVersionTable.PSVersion, $PSVersionTable.OS, $PSVersionTable.Platform -join " "]],
            },
            name = "pwsh",
            relaxed = not platform.is.win,
        },
    }

    if platform.is.unix then
        table.insert(checks, check { cmd = "bash", args = { "--version" }, name = "bash" })
        table.insert(checks, check { cmd = "sh", name = "sh" })
    end

    if platform.is.win then
        table.insert(checks, check { cmd = "python", args = { "--version" }, name = "python", relaxed = true })
        table.insert(
            checks,
            check { cmd = "python", args = { "-m", "pip", "--version" }, name = "pip", relaxed = true }
        )
        table.insert(checks, check { cmd = "7z", args = { "--help" }, name = "7z", relaxed = true })
    end

    if vim.g.python3_host_prog then
        table.insert(
            checks,
            check {
                cmd = vim.fn.expand(vim.g.python3_host_prog),
                args = { "--version" },
                name = "python3_host_prog",
                relaxed = true,
            }
        )
        table.insert(
            checks,
            check {
                cmd = vim.fn.expand(vim.g.python3_host_prog),
                args = { "-m", "pip", "--version" },
                name = "python3_host_prog pip",
                relaxed = true,
            }
        )
    end

    if vim.env.JAVA_HOME then
        table.insert(
            checks,
            check {
                cmd = ("%s/bin/java"):format(vim.env.JAVA_HOME),
                args = { "-version" },
                name = "JAVA_HOME",
                use_stderr = true,
                relaxed = true,
            }
        )
    end

    table.insert(checks, function()
        github_client
            .fetch_rate_limit()
            :map(
                ---@param rate_limit GitHubRateLimitResponse
                function(rate_limit)
                    a.scheduler()
                    local remaining = rate_limit.resources.core.remaining
                    local used = rate_limit.resources.core.used
                    local limit = rate_limit.resources.core.limit
                    local reset = rate_limit.resources.core.reset
                    local diagnostics = ("Used: %d. Remaining: %d. Limit: %d. Reset: %s."):format(
                        used,
                        remaining,
                        limit,
                        vim.fn.strftime("%c", reset)
                    )
                    if remaining <= 0 then
                        health.report_error(("GitHub API rate limit exceeded. %s"):format(diagnostics))
                    else
                        health.report_ok(("GitHub API rate limit. %s"):format(diagnostics))
                    end
                end
            )
            :on_failure(function()
                a.scheduler()
                health.report_warn "Failed to check GitHub API rate limit status."
            end)
    end)

    a.run_blocking(function()
        for _, c in ipairs(checks) do
            c()
        end
    end)
end

return M
