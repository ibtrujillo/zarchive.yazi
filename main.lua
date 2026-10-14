local P = require("zeppelin")

local M = {}

local function join(...)
  local t = {}
  for _, list in ipairs { ... } do
    for _, v in ipairs(list) do
      t[#t + 1] = v
    end
  end
  return t
end


local yanked = ya.sync(function()
  local items = {}
  for _, f in pairs(cx.yanked) do
    items[#items + 1] = { path = tostring(f.url), dir = f.cha.is_dir }
  end
  return { cwd = tostring(cx.active.current.cwd), items = items }
end)

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

local function compress_command(key, out, items, pwd, header, vol)
  local enc = pwd and { "-p" .. pwd } or {}
  local split = vol and { "-v" .. vol } or {}
  if P.FORMATS[key].tar then
    local script = '7zz a -ttar -so x.tar "${@:2}" | 7zz a -t' .. P.FORMATS[key].tar .. ' -si "$1"'
    return Command("bash"):arg(join({ "-o", "pipefail", "-c", script, "_", out }, items))
  elseif key == "zip" then
    return Command("7zz"):arg(join({ "a", "-tzip" }, pwd and { "-mem=AES256" } or {}, enc, split, { out }, items))
  elseif key == "7z" then
    return Command("7zz"):arg(join({ "a" }, header and { "-mhe=on" } or {}, enc, split, { out }, items))
  elseif key == "tar" then
    return Command("7zz"):arg(join({ "a", "-ttar", out }, items))
  elseif key == "gz" then
    return Command("7zz"):arg(join({ "a", "-tgzip", out }, items))
  elseif key == "rar" then
    return Command("rar"):arg(join({ "a" }, pwd and { (header and "-hp@" or "-p@") .. pwd } or {}, split, { out }, items))
  end
end

local function unique_path(cwd, base, suffix)
  local name, n = base .. suffix, 0
  while fs.cha(Url(cwd .. "/" .. name)) do
    n = n + 1
    name = base .. "_" .. n .. suffix
  end
  return cwd .. "/" .. name
end

-- shortcut: confirm body has no scroll view, shows CONFIRM_MAX_LINES lines and "… N more"; replace with native scroll when yazi offers one for ya.confirm
local CONFIRM_MAX_LINES = 11

local function confirm_list(sel)
  local lines = {}
  local total = #sel.items
  local shown = total > CONFIRM_MAX_LINES and CONFIRM_MAX_LINES - 1 or total
  for i = 1, shown do
    local it = sel.items[i]
    local icon = th.icon:match(File { url = Url(it.path), cha = Cha { mode = tonumber(it.dir and "40700" or "100644", 8) } })
    lines[#lines + 1] = ui.Line { ui.Span("  "), icon and ui.Span(icon.text .. " "):style(icon.style) or ui.Span("  "), ui.Span(it.path) }:align(ui.Align.LEFT)
  end
  if total > shown then
    lines[#lines + 1] = ui.Line { ui.Span(string.format("  \u{2026} %d more", total - shown)) }:align(ui.Align.LEFT)
  end
  return ya.confirm {
    pos = { "center", w = 80, h = math.min(#lines + 4, 30) },
    title = string.format("Compress %d selected files?", #sel.items),
    body = ui.Text(lines):align(ui.Align.LEFT),
  }
end

local function selection_bytes(paths)
  local out = Command("du"):arg(join({ "-sbL", "--" }, paths)):stdin(Command.NULL):stderr(Command.NULL):output()
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
  local bytes, err = P.volume_bytes(spec, total)
  if not bytes then
    return nil, err
  end
  return bytes
end

local function compress(split)
  local sel = yanked()
  if #sel.items == 0 then
    ya.notify { title = "Compress", content = "Nothing yanked: select with space, then y", level = "warn", timeout = 5 }
    return
  end

  local paths = {}
  for _, it in ipairs(sel.items) do
    if not fs.cha(Url(it.path)) then
      ya.notify { title = "Compress", content = "Yanked item missing: " .. it.path .. " (yank again)", level = "error", timeout = 10 }
      return
    end
    paths[#paths + 1] = it.path
  end

  if not confirm_list(sel) then
    return
  end

  local default = sel.cwd:match("[^/]+$") or "archive"
  local name, event = ya.input { pos = { "top-center", y = 2, w = 50 }, title = "Archive name:", value = default .. ".zip" }
  if event ~= 1 or name == "" then
    return
  end
  local base, key = P.split_format(name)
  if not key then
    ya.notify { title = "Compress", content = "Unknown archive format", level = "error", timeout = 10 }
    return
  end

  local fmt = P.FORMATS[key]
  if split and not fmt.split then
    ya.notify { title = "Compress", content = "Format has no multi-volume support", level = "error", timeout = 10 }
    return
  end

  local spec
  if split then
    local value, sevent = ya.input { pos = { "top-center", y = 2, w = 50 }, title = "Parts (e.g. 4) or volume size (e.g. 5.5MB, 89kiB):" }
    if sevent ~= 1 or value == "" then
      return
    end
    spec = value
  end

  local pwd, header
  if fmt.password then
    local value, pevent = ya.input { pos = { "top-center", y = 2, w = 50 }, title = "Password (empty = none):", obscure = true }
    if pevent ~= 1 then
      return
    end
    if value ~= "" then
      pwd = value
      if fmt.header then
        header = ya.confirm {
          pos = { "center", w = 60, h = 8 },
          title = "Encrypt file names?",
          body = ui.Text("Without this, file names stay visible without the password."),
        }
      end
    end
  end

  local entries = P.drop_nested(paths)
  local vol, why
  if spec then
    vol, why = volume_size(spec, entries)
    if not vol then
      ya.notify { title = "Compress", content = why, level = "error", timeout = 10 }
      return
    end
  end

  local pwdir
  if pwd and key == "rar" then
    pwdir = P.password_file(pwd)
    if not pwdir then
      ya.notify { title = "Compress", content = "Failed to store password", level = "error", timeout = 10 }
      return
    end
    pwd = pwdir .. "/pw"
  end

  local names = P.entry_names(entries)
  local root = stage(entries, names)
  if not root then
    if pwdir then
      Command("rm"):arg({ "-rf", pwdir }):output()
    end
    ya.notify { title = "Compress", content = "Failed to stage selection", level = "error", timeout = 10 }
    return
  end

  local out = unique_path(sel.cwd, base, "." .. key)
  local cmd = compress_command(key, out, names, pwd, header, vol)
  local res = cmd and cmd:cwd(root):stdin(Command.NULL):stdout(Command.NULL):stderr(Command.PIPED):output()
  Command("rm"):arg({ "-rf", root }):output()
  if pwdir then
    Command("rm"):arg({ "-rf", pwdir }):output()
  end

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
  ya.notify { title = "Compress", content = msg, level = "error", timeout = 10 }
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
