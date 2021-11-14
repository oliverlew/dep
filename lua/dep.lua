local logger = require("dep/log")
local proc = require("dep/proc")

logger:open()

local initialized, config_path, base_dir
local packages, package_roots

local function get_name(id)
  local name = id:match("^[%w-_.]+/([%w-_.]+)$")
  if name then
    return name
  else
    error(string.format('invalid name "%s"; must be in the format "user/package"', id))
  end
end

local function link_dependency(parent, child)
  if not parent.dependents[child.id] then
    parent.dependents[child.id] = child
    parent.dependents[#parent.dependents + 1] = child
  end

  if not child.dependencies[parent.id] then
    child.dependencies[parent.id], child.root = parent, false
    child.dependencies[#child.dependencies + 1] = parent
  end
end

local function register(spec, overrides)
  overrides = overrides or {}

  if type(spec) ~= "table" then
    spec = { spec }
  end

  local id = spec[1]
  local package = packages[id]

  if not package then
    package = {
      id = id,
      enabled = true,
      exists = false,
      added = false,
      configured = false,
      loaded = false,
      on_setup = {},
      on_config = {},
      on_load = {},
      root = true,
      dependencies = {}, -- inward edges
      dependents = {}, -- outward edges
    }

    packages[id] = package
    packages[#packages + 1] = package
  end

  local prev_dir = package.dir -- optimization

  -- meta
  package.name = spec.as or package.name or get_name(id)
  package.url = spec.url or package.url or ("https://github.com/" .. id .. ".git")
  package.branch = spec.branch or package.branch
  package.dir = base_dir .. package.name
  package.pin = overrides.pin or spec.pin or package.pin
  package.enabled = not overrides.disable and not spec.disable and package.enabled

  if prev_dir ~= package.dir then
    package.exists = vim.fn.isdirectory(package.dir) ~= 0
    package.configured = package.exists
  end

  package.on_setup[#package.on_setup + 1] = spec.setup
  package.on_config[#package.on_config + 1] = spec.config
  package.on_load[#package.on_load + 1] = spec[2]

  if type(spec.requires) == "table" then
    for i = 1, #spec.requires do
      link_dependency(register(spec.requires[i]), package)
    end
  elseif spec.requires then
    link_dependency(register(spec.requires), package)
  end

  if type(spec.deps) == "table" then
    for i = 1, #spec.deps do
      link_dependency(package, register(spec.deps[i]))
    end
  elseif spec.deps then
    link_dependency(package, register(spec.deps))
  end

  return package
end

local function register_recursive(list, overrides)
  overrides = overrides or {}
  overrides = {
    pin = overrides.pin or list.pin,
    disable = overrides.disable or list.disable,
  }

  for i = 1, #list do
    local ok, err = pcall(register, list[i], overrides)
    if not ok then
      error(string.format("%s (spec=%s)", err, vim.inspect(list[i])))
    end
  end

  if list.modules then
    for i = 1, #list.modules do
      local name, module = "<unnamed module>", list.modules[i]

      if type(module) == "string" then
        name, module = module, require(module)
      end

      name = module.name or name

      local ok, err = pcall(register_recursive, module, overrides)
      if not ok then
        error(string.format("%s <- %s", err, name))
      end
    end
  end
end

local function sort_dependencies()
  local function compare(a, b)
    local a_deps = #a.dependencies
    local b_deps = #b.dependencies

    if a_deps == b_deps then
      return a.id < b.id
    else
      return a_deps < b_deps
    end
  end

  table.sort(packages, compare)

  for i = 1, #packages do
    table.sort(packages[i].dependencies, compare)
    table.sort(packages[i].dependents, compare)
  end
end

local function find_cycle()
  local index = 0
  local indexes = {}
  local lowlink = {}
  local stack = {}

  -- use tarjan algorithm to find circular dependencies (strongly connected components)
  local function connect(package)
    indexes[package.id], lowlink[package.id] = index, index
    stack[#stack + 1], stack[package.id] = package, true
    index = index + 1

    for i = 1, #package.dependents do
      local dependent = package.dependents[i]

      if not indexes[dependent.id] then
        local cycle = connect(dependent)
        if cycle then
          return cycle
        else
          lowlink[package.id] = math.min(lowlink[package.id], lowlink[dependent.id])
        end
      elseif stack[dependent.id] then
        lowlink[package.id] = math.min(lowlink[package.id], indexes[dependent.id])
      end
    end

    if lowlink[package.id] == indexes[package.id] then
      local cycle = { package }
      local node

      repeat
        node = stack[#stack]
        stack[#stack], stack[node.id] = nil, nil
        cycle[#cycle + 1] = node
      until node == package

      -- a node is by definition strongly connected to itself
      -- ignore single-node components unless it explicitly specified itself as a dependency
      if #cycle > 2 or package.dependents[package.id] then
        return cycle
      end
    end
  end

  for i = 1, #packages do
    local package = packages[i]

    if not indexes[package.id] then
      local cycle = connect(package)
      if cycle then
        return cycle
      end
    end
  end
end

local function ensure_acyclic()
  local cycle = find_cycle()

  if cycle then
    local names = {}
    for i = 1, #cycle do
      names[i] = cycle[i].id
    end
    error("circular dependency detected in package graph: " .. table.concat(names, " -> "))
  end
end

local function find_roots()
  for i = 1, #packages do
    local package = packages[i]
    if package.root then
      package_roots[#package_roots + 1] = package
    end
  end
end

local function run_hooks(package, type)
  local hooks = package[type]

  for i = 1, #hooks do
    local ok, err = pcall(hooks[i])
    if not ok then
      package.error = true
      return false, err
    end
  end

  if #hooks ~= 0 then
    logger:log(
      "hook",
      string.format("ran %d %s %s for %s", #hooks, type, #hooks == 1 and "hook" or "hooks", package.id)
    )
  end

  return true
end

local function ensure_added(package)
  if not package.added then
    local ok, err = pcall(vim.cmd, "packadd " .. package.name)
    if ok then
      package.added = true
      logger:log("vim", string.format("packadd completed for %s", package.id))
    else
      package.error = true
      return false, err
    end
  end

  return true
end

local function configure_recursive(package)
  if not package.exists or not package.enabled or package.error then
    return
  end

  for i = 1, #package.dependencies do
    if not package.dependencies[i].configured then
      return
    end
  end

  local propagate = false

  if not package.configured then
    local ok, err = run_hooks(package, "on_setup")
    if not ok then
      logger:log("error", string.format("failed to set up %s; reason: %s", package.id, err))
      return
    end

    ok, err = ensure_added(package)
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    ok, err = run_hooks(package, "on_config")
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    package.configured, package.loaded = true, false
    propagate = true

    logger:log("config", string.format("configured %s", package.id))
  end

  for i = 1, #package.dependents do
    local dependent = package.dependents[i]

    dependent.configured = dependent.configured and not propagate
    configure_recursive(dependent)
  end
end

local function load_recursive(package)
  if not package.exists or not package.enabled or package.error then
    return
  end

  for i = 1, #package.dependencies do
    if not package.dependencies[i].loaded then
      return
    end
  end

  local propagate = false

  if not package.loaded then
    local ok, err = ensure_added(package)
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    ok, err = run_hooks(package, "on_load")
    if not ok then
      logger:log("error", string.format("failed to load %s; reason: %s", package.id, err))
      return
    end

    package.loaded = true
    propagate = true

    logger:log("load", string.format("loaded %s", package.id))
  end

  for i = 1, #package.dependents do
    local dependent = package.dependents[i]

    dependent.loaded = dependent.loaded and not propagate
    load_recursive(dependent, force)
  end
end

local function reload_meta()
  local ok, err = pcall(
    vim.cmd,
    [[
      silent! helptags ALL
      silent! UpdateRemotePlugins
    ]]
  )

  if ok then
    logger:log("vim", "reloaded helptags and remote plugins")
  else
    logger:log("error", string.format("failed to reload helptags and remote plugins; reason: %s", err))
  end
end

local function reload_all()
  -- clear all errors and try again
  for i = 1, #packages do
    packages[i].error = false
  end

  for i = 1, #package_roots do
    configure_recursive(package_roots[i])
  end

  for i = 1, #package_roots do
    load_recursive(package_roots[i])
  end

  reload_meta()
end

local function clean()
  vim.loop.fs_scandir(
    base_dir,
    vim.schedule_wrap(function(err, handle)
      if err then
        logger:log("error", string.format("failed to clean; reason: %s", err))
      else
        local queue = {}

        while handle do
          local name = vim.loop.fs_scandir_next(handle)
          if name then
            queue[name] = base_dir .. name
          else
            break
          end
        end

        for i = 1, #packages do
          queue[packages[i].name] = nil
        end

        for name, dir in pairs(queue) do
          -- todo: make this async
          local ok = vim.fn.delete(dir, "rf")
          if ok then
            logger:log("clean", string.format("deleted %s", name))
          else
            logger:log("error", string.format("failed to delete %s", name))
          end
        end
      end
    end)
  )
end

local function sync(package, cb)
  if not package.enabled then
    return
  end

  if package.exists then
    if package.pin then
      return
    end

    local function log_err(err)
      logger:log("error", string.format("failed to update %s; reason: %s", package.id, err))
    end

    proc.git_rev_parse(package.dir, "HEAD", function(err, before)
      if err then
        log_err(before)
        cb(err)
      else
        proc.git_fetch(package.dir, "origin", package.branch or "HEAD", function(err, message)
          if err then
            log_err(message)
            cb(err)
          else
            proc.git_rev_parse(package.dir, "FETCH_HEAD", function(err, after)
              if err then
                log_err(after)
                cb(err)
              elseif before == after then
                logger:log("skip", string.format("skipped %s", package.id))
                cb(err)
              else
                proc.git_reset(package.dir, after, function(err, message)
                  if err then
                    log_err(message)
                  else
                    package.added, package.configured = false, false
                    logger:log("update", string.format("updated %s; %s -> %s", package.id, before, after))
                  end

                  cb(err)
                end)
              end
            end)
          end
        end)
      end
    end)
  else
    proc.git_clone(package.dir, package.url, package.branch, function(err, message)
      if err then
        logger:log("error", string.format("failed to install %s; reason: %s", package.id, message))
      else
        package.exists, package.added, package.configured = true, false, false
        logger:log("install", string.format("installed %s", package.id))
      end

      cb(err)
    end)
  end
end

local function sync_list(list)
  local progress = 0
  local has_errors = false

  local function done(err)
    progress = progress + 1
    has_errors = has_errors or err

    if progress == #list then
      clean()
      reload_all()

      if has_errors then
        logger:log("error", "there were errors during sync; see :messages or :DepLog for more information")
      end
    end
  end

  for i = 1, #list do
    sync(list[i], done)
  end
end

local function print_list(list)
  local buffer = vim.api.nvim_create_buf(true, true)
  local line = 0
  local indent = 0

  local function print(chunks)
    local concat = {}
    local column = 0

    for i = 1, indent do
      concat[#concat + 1] = "  "
      column = column + 2
    end

    if not chunks then
      chunks = {}
    elseif type(chunks) == "string" then
      chunks = { { chunks } }
    end

    for i = 1, #chunks do
      local chunk = chunks[i]
      concat[#concat + 1] = chunk[1]
      chunk.offset, column = column, column + #chunk[1]
    end

    vim.api.nvim_buf_set_lines(buffer, line, -1, false, { table.concat(concat) })

    for i = 1, #chunks do
      local chunk = chunks[i]
      if chunk[2] then
        vim.api.nvim_buf_add_highlight(buffer, -1, chunk[2], line, chunk.offset, chunk.offset + #chunk[1])
      end
    end

    line = line + 1
  end

  print("Installed packages:")
  indent = 1

  local loaded = {}

  local function dry_load(package)
    for i = 1, #package.dependencies do
      if not loaded[package.dependencies[i].id] then
        return
      end
    end

    loaded[package.id] = true

    local line = {
      { "- ", "Comment" },
      { package.id, "Underlined" },
    }

    if not package.exists then
      line[#line + 1] = { " *not installed", "Comment" }
    end

    if not package.loaded then
      line[#line + 1] = { " *not loaded", "Comment" }
    end

    if not package.enabled then
      line[#line + 1] = { " *disabled", "Comment" }
    end

    if package.pin then
      line[#line + 1] = { " *pinned", "Comment" }
    end

    print(line)

    for i = 1, #package.dependents do
      dry_load(package.dependents[i])
    end
  end

  for i = 1, #package_roots do
    dry_load(package_roots[i])
  end

  indent = 0
  print()
  print("Dependency graph:")

  local function walk_graph(package)
    indent = indent + 1

    print({
      { "| ", "Comment" },
      { package.id, "Underlined" },
    })

    for i = 1, #package.dependents do
      walk_graph(package.dependents[i])
    end

    indent = indent - 1
  end

  for i = 1, #package_roots do
    walk_graph(package_roots[i])
  end

  vim.api.nvim_buf_set_name(buffer, "packages.dep")
  vim.api.nvim_buf_set_option(buffer, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buffer, "modifiable", false)

  vim.cmd("sp")
  vim.api.nvim_win_set_buf(0, buffer)
end

vim.cmd([[
  command! DepSync lua require("dep").sync()
  command! DepReload lua require("dep").reload()
  command! DepClean lua require("dep").clean()
  command! DepList lua require("dep").list()
  command! DepLog lua require("dep").open_log()
  command! DepConfig lua require("dep").open_config()
]])

local function wrap_api(name, fn)
  return function(...)
    if initialized then
      local ok, err = pcall(fn, ...)
      if not ok then
        logger:log("error", err)
      end
    else
      logger:log("error", string.format("cannot call %s; dep is not initialized", name))
    end
  end
end

--todo: prevent multiple execution of async routines
return setmetatable({
  sync = wrap_api("dep.sync", function()
    sync_list(packages)
  end),

  reload = wrap_api("dep.reload", reload_all),
  clean = wrap_api("dep.clean", clean),

  list = wrap_api("dep.list", function()
    print_list(packages)
  end),

  open_log = wrap_api("dep.open_log", function()
    vim.cmd("sp " .. logger.path)
  end),

  open_config = wrap_api("dep.open_config", function()
    vim.cmd("sp " .. config_path)
  end),
}, {
  __call = function(self, config)
    config_path = debug.getinfo(2, "S").source:sub(2)
    initialized, err = pcall(function()
      base_dir = config.base_dir or (vim.fn.stdpath("data") .. "/site/pack/deps/opt/")
      packages, package_roots = {}, {}

      register("chiyadev/dep")
      register_recursive(config)
      sort_dependencies()
      ensure_acyclic()
      find_roots()
      reload_all()

      local should_sync = function(package)
        if config.sync == "new" or config.sync == nil then
          return not package.exists
        else
          return config.sync == "always"
        end
      end

      local targets = {}

      for i = 1, #packages do
        local package = packages[i]
        if should_sync(package) then
          targets[#targets + 1] = package
        end
      end

      sync_list(targets)
    end)

    if not initialized then
      logger:log("error", err)
    end
  end,
})
