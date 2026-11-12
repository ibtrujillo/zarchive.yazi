# zarchive.yazi

Compress the selected files or directories into an archive from Yazi, with
optional password encryption and multi-volume split output.

## Requirements

- Yazi 26.9.1 or newer
- `7zz` (7-Zip)
- [zeppelin.yazi](https://github.com/ibtrujillo/zeppelin.yazi)

## Installation

```sh
ya pkg add ibtrujillo/zarchive
ya pkg add ibtrujillo/zeppelin
```

## Usage

```lua
-- keymap.toml
[mgr]
prepend_keymap = [
  { on = ["z"], run = "plugin zarchive compress", desc = "compress" },
  { on = ["Z"], run = "plugin zarchive split", desc = "split compress" },
]
```

`compress` asks for the archive name, an optional password and the format.
`split` also asks for the volume size.
