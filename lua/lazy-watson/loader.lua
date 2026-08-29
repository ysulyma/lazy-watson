-- Lazy Watson - Loader Module
-- Inlang config & message loading

local M = {}

--- Find the project root by walking up directories
---@param start_path string Starting file path
---@param pattern string Pattern to look for (e.g., "project.inlang/settings.json")
---@return string|nil Project root path or nil if not found
function M.find_project_root(start_path, pattern)
  local path = vim.fn.fnamemodify(start_path, ":p:h")

  while path and path ~= "/" and path ~= "" do
    local settings_path = path .. "/" .. pattern
    if vim.fn.filereadable(settings_path) == 1 then
      return path
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then
      break
    end
    path = parent
  end

  return nil
end

--- Normalize a pathPattern value (string or string[]) into a flat list of strings.
---@param value string|string[] A single pattern or array of patterns
---@return string[] List of pattern strings
local function normalize_path_patterns(value)
  if type(value) == "string" then
    return { value }
  end
  if type(value) == "table" then
    local result = {}
    for _, v in ipairs(value) do
      if type(v) == "string" then
        table.insert(result, v)
      end
    end
    if #result > 0 then
      return result
    end
  end
  return nil
end

--- Load inlang settings from project.inlang/settings.json
---@param root string Project root path
---@param pattern string Settings file pattern
---@return table|nil Settings table { baseLocale, locales, pathPattern: string[] } or nil on error
function M.load_settings(root, pattern)
  local settings_path = root .. "/" .. pattern
  local content = M._read_file(settings_path)

  if not content then
    return nil
  end

  local ok, settings = pcall(vim.json.decode, content)
  if not ok then
    vim.notify("Failed to parse inlang settings: " .. tostring(settings), vim.log.levels.ERROR)
    return nil
  end

  -- Extract relevant fields
  local base_locale = settings.baseLocale
  local locales = settings.locales

  -- Find pathPattern from plugin settings
  -- Any top-level key starting with "plugin." may contain a pathPattern
  -- pathPattern can be a string or an array of strings
  local path_patterns = nil

  for key, value in pairs(settings) do
    if type(key) == "string" and key:find("^plugin%.") and type(value) == "table" and value.pathPattern then
      path_patterns = normalize_path_patterns(value.pathPattern)
      if path_patterns then
        break
      end
    end
  end

  -- Fallback: check for common patterns
  if not path_patterns then
    local common_patterns = {
      -- {locale} is preferred
      "./messages/{locale}.json",
      "./src/messages/{locale}.json",
      "./locales/{locale}.json",
      "./i18n/{locale}.json",
      -- {languageTag} is legacy but still supported
      "./messages/{languageTag}.json",
      "./src/messages/{languageTag}.json",
      "./locales/{languageTag}.json",
      "./i18n/{languageTag}.json",
    }

    local fallback_locale = base_locale or "en"
    for _, pat in ipairs(common_patterns) do
      local test_path = root .. "/" .. pat:gsub("{locale}", fallback_locale):gsub("{languageTag}", fallback_locale)
      if vim.fn.filereadable(test_path) == 1 then
        path_patterns = { pat }
        break
      end
    end
  end

  if not base_locale or not locales then
    vim.notify("Inlang settings missing baseLocale or locales", vim.log.levels.WARN)
    return nil
  end

  return {
    baseLocale = base_locale,
    locales = locales,
    pathPattern = path_patterns or { "./messages/{languageTag}.json" },
  }
end

--- Resolve a single path pattern to a full filesystem path
---@param root string Project root path
---@param pattern string A single path pattern with {locale} or {languageTag} placeholder
---@param locale string Locale code
---@return string Full path to message file
local function resolve_pattern(root, pattern, locale)
  local relative_path = pattern:gsub("{locale}", locale):gsub("{languageTag}", locale)
  -- Handle ./ prefix
  if relative_path:sub(1, 2) == "./" then
    relative_path = relative_path:sub(3)
  end
  return root .. "/" .. relative_path
end

--- Get all resolved message file paths for the given patterns
---@param root string Project root path
---@param patterns string[] List of path patterns with {locale} or {languageTag} placeholder
---@param locale string Locale code
---@return string[] List of full paths to message files
function M.get_message_paths(root, patterns, locale)
  local paths = {}
  for _, pattern in ipairs(patterns) do
    table.insert(paths, resolve_pattern(root, pattern, locale))
  end
  return paths
end

--- Load messages for a specific locale from all path patterns
---@param root string Project root path
---@param patterns string[] List of path patterns with {locale} or {languageTag} placeholder
---@param locale string Locale code
---@return table Message key-value map (merged from all matching files)
function M.load_messages(root, patterns, locale)
  local merged = {}

  for _, pattern in ipairs(patterns) do
    local message_path = resolve_pattern(root, pattern, locale)
    local content = M._read_file(message_path)

    if content then
      local ok, messages = pcall(vim.json.decode, content)
      if not ok then
        vim.notify("Failed to parse messages for " .. locale .. ": " .. tostring(messages), vim.log.levels.ERROR)
      else
        local flat = M._flatten_messages(messages)
        for k, v in pairs(flat) do
          merged[k] = v
        end
      end
    end
  end

  return merged
end

--- Flatten messages to a simple key-value map
--- Handles complex formats like arrays, nested objects, etc.
---@param messages table Raw messages object
---@param prefix string|nil Key prefix for nested objects
---@return table Flattened key-value map
function M._flatten_messages(messages, prefix)
  local result = {}
  prefix = prefix or ""

  for key, value in pairs(messages) do
    local full_key = prefix == "" and key or (prefix .. "." .. key)

    if type(value) == "string" then
      result[full_key] = value
    elseif type(value) == "table" then
      -- Check if it's an array (inlang message format with variants)
      if #value > 0 then
        -- Use first variant's value if it exists
        if type(value[1]) == "table" and value[1].value then
          result[full_key] = M._extract_pattern_value(value[1].value)
        elseif type(value[1]) == "string" then
          result[full_key] = value[1]
        end
      else
        -- Check for direct value property (another common format)
        if value.value then
          result[full_key] = M._extract_pattern_value(value.value)
        else
          -- Recurse into nested object
          local nested = M._flatten_messages(value, full_key)
          for k, v in pairs(nested) do
            result[k] = v
          end
        end
      end
    end
  end

  return result
end

--- Extract text value from inlang pattern format
---@param value any Pattern value (string, array, or table)
---@return string Extracted text
function M._extract_pattern_value(value)
  if type(value) == "string" then
    return value
  elseif type(value) == "table" then
    -- Handle pattern array format: [{ type: "text", value: "..." }, ...]
    local parts = {}
    for _, part in ipairs(value) do
      if type(part) == "table" then
        if part.type == "text" and part.value then
          table.insert(parts, part.value)
        elseif part.type == "variable" or part.type == "VariableReference" then
          -- Include variable placeholder
          local name = part.name or part.arg or "?"
          table.insert(parts, "{" .. name .. "}")
        end
      elseif type(part) == "string" then
        table.insert(parts, part)
      end
    end
    return table.concat(parts, "")
  end
  return tostring(value)
end

--- Read file content
---@param path string File path
---@return string|nil Content or nil on error
function M._read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*all")
  file:close()

  return content
end

return M
