local M = {}

local Log = require "lvim.core.log"
local fmt = string.format
local if_nil = vim.F.if_nil

local function git_cmd(opts)
  local plenary_loaded, Job = pcall(require, "plenary.job")
  if not plenary_loaded then
    return 1, { "" }
  end

  opts = opts or {}
  opts.cwd = opts.cwd or get_lvim_base_dir()

  local stderr = {}
  local stdout, ret = Job:new({
    command = "git",
    args = opts.args,
    cwd = opts.cwd,
    on_stderr = function(_, data)
      table.insert(stderr, data)
    end,
  }):sync()

  if not vim.tbl_isempty(stderr) then
    Log:debug(stderr)
  end

  if not vim.tbl_isempty(stdout) then
    Log:debug(stdout)
  end

  return ret, stdout, stderr
end

local function safe_deep_fetch()
  local ret, result, error = git_cmd { args = { "rev-parse", "--is-shallow-repository" } }
  if ret ~= 0 then
    Log:error(vim.inspect(error))
    return
  end
  -- git fetch --unshallow will cause an error on a complete clone
  local fetch_mode = result[1] == "true" and "--unshallow" or "--all"
  ret = git_cmd { args = { "fetch", fetch_mode } }
  if ret ~= 0 then
    Log:error(fmt "Git fetch %s failed! Please pull the changes manually in %s", fetch_mode, get_lvim_base_dir())
    return
  end
  if fetch_mode == "--unshallow" then
    ret = git_cmd { args = { "remote", "set-branches", "origin", "*" } }
    if ret ~= 0 then
      Log:error(fmt "Git fetch %s failed! Please pull the changes manually in %s", fetch_mode, get_lvim_base_dir())
      return
    end
  end
  return true
end

---pulls the latest changes from github
function M.update_base_lvim()
  Log:info "Checking for updates"

  if not vim.loop.fs_access(get_lvim_base_dir(), "w") then
    Log:warn(fmt("Lunarvim update aborted! cannot write to %s", get_lvim_base_dir()))
    return
  end

  if not safe_deep_fetch() then
    return
  end

  local ret

  ret = git_cmd { args = { "diff", "--quiet", "@{upstream}" } }
  if ret == 0 then
    Log:info "LunarVim is already up-to-date"
    return
  end

  ret = git_cmd { args = { "merge", "--ff-only", "--progress" } }
  if ret ~= 0 then
    Log:error("Update failed! Please pull the changes manually in " .. get_lvim_base_dir())
    return
  end

  return true
end

function M.update_minor_version()
  Log:info "Checking for minor version updates"

  if not vim.loop.fs_access(get_lvim_base_dir(), "w") then
    Log:warn(fmt("Lunarvim update aborted! cannot write to %s", get_lvim_base_dir()))
    return
  end

  if not safe_deep_fetch() then
    return
  end

  local current_branch = M.get_lvim_branch()

  -- check if the current branch is a release branch
  local release_num = current_branch:match("^release%-(%d+)")
  if not release_num then
    Log:warn "You are not on a release branch, switching to a minor version is not possible"
    return
  end

  -- check if any branch for a minor version exists
  local minor_version_branches = {}
  for _, branch in ipairs(M.get_git_branches()) do
    local minor_version = branch:match("^release%-(%d+)%.(%d+)")
    if minor_version and minor_version[1] == release_num then
      table.insert(minor_version_branches, branch)
    end
  end

  if #minor_version_branches == 0 then
    Log:warn "No minor version found for current release"
    return
  end

  -- find the latest minor version branch and switch to it
  table.sort(minor_version_branches)
  local latest_minor_version = minor_version_branches[#minor_version_branches]
  M.switch_lvim_branch(latest_minor_version)
end

---Switch Lunarvim to the specified development branch
---@param branch string
function M.switch_lvim_branch(branch)
  if not safe_deep_fetch() then
    return
  end
  local args = { "switch", branch }

  if branch:match "^[0-9]" then
    -- avoids producing an error for tags
    vim.list_extend(args, { "--detach" })
  end

  local ret = git_cmd { args = args }
  if ret ~= 0 then
    Log:error "Unable to switch branches! Check the log for further information"
    return
  end
  return true
end

---Get the current Lunarvim development branch
---@return string|nil
function M.get_lvim_branch()
  local _, results = git_cmd { args = { "rev-parse", "--abbrev-ref", "HEAD" } }
  local branch = if_nil(results[1], "")
  return branch
end

---Get currently checked-out tag of Lunarvim
---@return string
function M.get_lvim_tag()
  local args = { "describe", "--tags", "--abbrev=0" }

  local _, results = git_cmd { args = args }
  local tag = if_nil(results[1], "")
  return tag
end

---Get the description of currently checked-out commit of Lunarvim
---@return string|nil
function M.get_lvim_description()
  local _, results = git_cmd { args = { "describe", "--dirty", "--always" } }

  local description = if_nil(results[1], M.get_lvim_branch())
  return description
end

---Get currently running version of Lunarvim
---@return string
function M.get_lvim_version()
  local current_branch = M.get_lvim_branch()

  local lvim_version
  if current_branch ~= "HEAD" or "" then
    lvim_version = current_branch .. "-" .. M.get_lvim_description()
  else
    lvim_version = "v" .. M.get_lvim_tag()
  end
  return lvim_version
end

---Get all git branches
---@return table
function M.get_git_branches()
  local _, results = git_cmd { args = { "branch", "--all" } }

  local branches = {}
  for _, branch in ipairs(results) do
    branch = branch:gsub("^%s*", "") -- Remove leading white space
    if branch ~= "" then
      -- filter by remote branches
      -- TODO:
      if branch:match("^remotes") then
        branch = branch:gsub("^remotes/origin/", "")
      end
      table.insert(branches, branch)
    end
  end

  return branches
end

return M
