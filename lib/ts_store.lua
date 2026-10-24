-- The PSET sidecar: every sequence's strokes and settings, plus the selection, saved beside a PSET as
-- `<pset>.tabletseq`. norns's tab, the file checks and the model are passed in; no norns globals; Lua 5.3.
--   tab: save(data, path), load(path) -> table|nil;  model: ts_model (sanitize_set)
--   exists(path) -> truthy;  remove(path)
local Store = {}

function Store.path_for(pset_filename)
  return pset_filename .. ".tabletseq"
end

function Store.new(opts)
  local tab, model, exists, remove = opts.tab, opts.model, opts.exists, opts.remove
  local self = { path_for = Store.path_for }

  -- set is { selected, sequences }; the empty page (a selection past the last sequence) is saved as none
  function self.save(path, set)
    local selected = set.selected
    if selected and selected > #set.sequences then selected = nil end
    tab.save({ selected = selected, sequences = set.sequences }, path)
  end

  -- The sanitized set, or nil when the file is missing, unreadable or holds no set.
  function self.load(path)
    if not exists(path) then return nil end
    local ok, raw = pcall(tab.load, path)
    if not ok then return nil end
    return model.sanitize_set(raw)
  end

  function self.delete(path)
    if exists(path) then remove(path) end
  end

  return self
end

return Store
