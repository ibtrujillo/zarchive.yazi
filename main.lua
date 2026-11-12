--- @since 26.9.1

local P = require("zeppelin")

local M = {}

local yanked = ya.sync(function()
  local items = {}
  for _, f in pairs(cx.yanked) do
    items[#items + 1] = { path = tostring(f.url), dir = f.cha.is_dir }
  end
  return { cwd = tostring(cx.active.current.cwd), items = items }
end)

local function notify_error(content)
  ya.notify { title = "Compress", content = content, level = "error", timeout = 10 }
end

local function stage(paths, names)
  local root = P.temp_dir()
  if not root then
    return
  end
  for i, p in ipairs(paths) do
    local dest = root .. "/" .. names[i]
    local made = Command("mkdir"):arg({ "-p", dest:match("^(.*)/[^/]+$") }):output()
    local link = made and made.status.success and Command("ln"):arg({ "-s", p, dest }):output()
    if not link or not link.status.success then
      Command("rm"):arg({ "-rf", root }):output()
      return
    end
  end
  return root
end

local function unique_path(cwd, base, suffix)
  local name, n = base .. suffix, 0
  while fs.cha(Url(cwd .. "/" .. name)) do
    n = n + 1
    name = base .. "_" .. n .. suffix
  end
  return cwd .. "/" .. name
end

local function item_paths(items)
  local paths = {}
  for i, it in ipairs(items) do
    paths[i] = it.path
  end
  return paths
end

local function all_exist(items)
  for _, it in ipairs(items) do
    if not fs.cha(Url(it.path)) then
      notify_error("Yanked item missing: " .. it.path .. " (yank again)")
      return false
    end
  end
  return true
end

local function ask_name(cwd)
  local default = cwd:match("[^/]+$") or "archive"
  local name, event = ya.input { pos = { "top-center", y = 2, w = 50 }, title = "Archive name:", value = default .. ".zip" }
  if event ~= 1 or name == "" then
    return
  end
  return name
end

local function ask_volume()
  local value, event = ya.input { pos = { "top-center", y = 2, w = 50 }, title = "Parts (e.g. 4) or volume size (e.g. 5.5MB, 89kiB):" }
  if event ~= 1 or value == "" then
    return
  end
  return value
end

local function ask_password(fmt)
  local value, event = ya.input { pos = { "top-center", y = 2, w = 50 }, title = "Password (empty = none):", obscure = true }
  if event ~= 1 then
    return nil, nil, false
  end
  if value == "" then
    return nil, nil, true
  end
  local header
  if fmt.header then
    header = ya.confirm {
      pos = { "center", w = 60, h = 8 },
      title = "Encrypt file names?",
      body = ui.Text("Without this, file names stay visible without the password."),
    }
  end
  return value, header, true
end

local function selection_bytes(paths)
  local out = Command("du"):arg(P.join({ "-sbL", "--" }, paths)):stdin(Command.NULL):stderr(Command.NULL):output()
  if not out or not out.status.success then
    return
  end
  local total = 0
  for line in out.stdout:gmatch("[^\n]+") do
    total = total + tonumber(line:match("^%d+"))
  end
  return total
end

local function volume_size(spec, paths)
  local total = selection_bytes(paths)
  if not total then
    return nil, "Cannot measure selection"
  end
  return P.volume_bytes(spec, total)
end

local function password_arg(key, pwd)
  if not (pwd and key == "rar") then
    return pwd
  end
  local dir = P.password_file(pwd)
  if dir then
    return dir .. "/pw", dir
  end
end

local function run_archive(root, names, cwd, base, key, pwd, header, vol)
  local out = unique_path(cwd, base, "." .. key)
  local program, args = P.archive_command(key, out, names, pwd, header, vol)
  local res = Command(program):arg(args):cwd(root):stdin(Command.NULL):stdout(Command.NULL):stderr(Command.PIPED):output()
  return res, out
end

local function report(res, out)
  ya.emit("escape", {})
  if res and res.status.success then
    return
  end
  if fs.cha(Url(out)) then
    fs.remove("file", Url(out))
  end
  local msg = "Failed to start compressor"
  if res then
    msg = res.stderr:find("Incorrect password", 1, true) and "Incorrect password" or res.stderr:match("[^\r\n]+") or "compressor failed"
  end
  notify_error(msg)
end

local function compress(split)
  local sel = yanked()
  if #sel.items == 0 then
    ya.notify { title = "Compress", content = "Nothing yanked: select with space, then y", level = "warn", timeout = 5 }
    return
  end
  if not all_exist(sel.items) then
    return
  end
  if not P.confirm_list(sel.items, string.format("Compress %d selected files?", #sel.items)) then
    return
  end

  local name = ask_name(sel.cwd)
  if not name then
    return
  end
  local base, key = P.split_format(name)
  if not key then
    return notify_error("Unknown archive format")
  end
  local fmt = P.FORMATS[key]
  if split and not fmt.split then
    return notify_error("Format has no multi-volume support")
  end

  local spec
  if split then
    spec = ask_volume()
    if not spec then
      return
    end
  end

  local pwd, header, asked = nil, nil, true
  if fmt.password then
    pwd, header, asked = ask_password(fmt)
  end
  if not asked then
    return
  end

  local entries = P.drop_nested(item_paths(sel.items))

  local vol
  if spec then
    local why
    vol, why = volume_size(spec, entries)
    if not vol then
      return notify_error(why)
    end
  end

  local pwd_arg, pwdir = password_arg(key, pwd)
  if pwd and not pwd_arg then
    return notify_error("Failed to store password")
  end

  local names = P.entry_names(entries)
  local root = stage(entries, names)
  if not root then
    if pwdir then
      Command("rm"):arg({ "-rf", pwdir }):output()
    end
    return notify_error("Failed to stage selection")
  end

  local res, out = run_archive(root, names, sel.cwd, base, key, pwd_arg, header, vol)
  Command("rm"):arg({ "-rf", root }):output()
  if pwdir then
    Command("rm"):arg({ "-rf", pwdir }):output()
  end
  report(res, out)
end

function M:entry(job)
  if job.args[1] == "compress" then
    return compress(false)
  end
  if job.args[1] == "split" then
    return compress(true)
  end
end

return M
