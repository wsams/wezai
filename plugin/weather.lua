-- @weather catalog for wezai — Open-Meteo forecast keyed by ZIP / postal code.
-- Plugin-set zip is persisted under ~/.local/share/wezai/weather.json (does not rewrite wezterm.lua).
local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")
local ui = require("ui")

local M = {}

local USER_AGENT = "wezai (https://github.com/wsams/wezai)"
local HTTP_TIMEOUT = 20

local WMO = {
    [0] = "Clear",
    [1] = "Mainly clear",
    [2] = "Partly cloudy",
    [3] = "Overcast",
    [45] = "Fog",
    [48] = "Rime fog",
    [51] = "Light drizzle",
    [53] = "Drizzle",
    [55] = "Dense drizzle",
    [56] = "Light freezing drizzle",
    [57] = "Freezing drizzle",
    [61] = "Slight rain",
    [63] = "Rain",
    [65] = "Heavy rain",
    [66] = "Light freezing rain",
    [67] = "Freezing rain",
    [71] = "Slight snow",
    [73] = "Snow",
    [75] = "Heavy snow",
    [77] = "Snow grains",
    [80] = "Slight showers",
    [81] = "Showers",
    [82] = "Heavy showers",
    [85] = "Slight snow showers",
    [86] = "Heavy snow showers",
    [95] = "Thunderstorm",
    [96] = "Thunderstorm + hail",
    [99] = "Thunderstorm + heavy hail",
}

local COMPASS = { "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW" }

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function weather_opts(config)
    local w = (config and config.weather) or {}
    return {
        zip = w.zip,
        country = w.country,
        units = w.units,
        path = w.path,
    }
end

local function data_dir()
    local xdg = os.getenv("XDG_DATA_HOME")
    if type(xdg) == "string" and xdg ~= "" then
        return xdg .. util.separator .. "wezai"
    end
    if util.is_windows then
        local localapp = os.getenv("LOCALAPPDATA")
        if type(localapp) == "string" and localapp ~= "" then
            return localapp .. util.separator .. "wezai"
        end
    end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
    return home .. util.separator .. ".local" .. util.separator .. "share" .. util.separator .. "wezai"
end

function M.store_path(config)
    local override = weather_opts(config).path
    if type(override) == "string" and override ~= "" then
        return override
    end
    return data_dir() .. util.separator .. "weather.json"
end

local function empty_store()
    return { zip = nil, country = nil, cache = nil }
end

function M.load_store(config)
    local path = M.store_path(config)
    local ok, raw = util.read_text_file(path, 256 * 1024)
    if not ok or not raw or raw == "" then
        return empty_store()
    end
    local parsed_ok, data = pcall(wezterm.json_parse, raw)
    if not parsed_ok or type(data) ~= "table" then
        return empty_store()
    end
    return data
end

function M.save_store(config, store)
    local path = M.store_path(config)
    util.ensure_parent_dir(path)
    local payload = {
        zip = store.zip,
        country = store.country,
        cache = store.cache,
    }
    local ok, err = util.write_text_file(path, wezterm.json_encode(payload) .. "\n")
    if not ok then
        wezterm.log_warn("wezai: could not write weather store: " .. tostring(err))
        return false, err
    end
    return true, nil
end

local function normalize_country(raw)
    local c = trim(raw or ""):upper()
    if c == "" then
        return "US"
    end
    return c
end

local function normalize_zip(raw)
    local z = trim(raw or ""):upper()
    z = z:gsub("%s+", " ")
    -- US ZIP+4 → 5-digit
    local five = z:match("^(%d%d%d%d%d)%-%d%d%d%d$")
    if five then
        return five
    end
    return z
end

--- Parse "90210", "90210, US", "M5V 2T6 CA", "SW1A 1AA, GB".
function M.parse_zip_input(raw, default_country)
    local s = trim(raw or "")
    if s == "" then
        return nil, nil
    end
    local postal, country = s:match("^(.-),%s*([A-Za-z][A-Za-z])$")
    if postal and country then
        return normalize_zip(postal), normalize_country(country)
    end
    -- "90210 US" / "M5V2T6 CA" — trailing ISO country when the rest still has a digit.
    local postal2, country2 = s:match("^(.-)%s+([A-Za-z][A-Za-z])$")
    if postal2 and country2 and postal2:match("%d") then
        return normalize_zip(postal2), normalize_country(country2)
    end
    return normalize_zip(s), normalize_country(default_country)
end

--- Effective zip: plugin overlay (`@weather:zip`) beats wezterm.lua `weather.zip`.
function M.resolved_location(config)
    local opts = weather_opts(config)
    local store = M.load_store(config)
    local zip, country
    if type(store.zip) == "string" and trim(store.zip) ~= "" then
        zip = normalize_zip(store.zip)
        country = normalize_country(store.country or opts.country)
    else
        zip = normalize_zip(opts.zip)
        country = normalize_country(opts.country)
    end
    if zip == "" then
        zip = nil
    end
    return {
        zip = zip,
        country = country,
        units = opts.units or "auto",
        store = store,
        from_plugin = type(store.zip) == "string" and trim(store.zip) ~= "",
    }
end

local function url_encode(s)
    s = tostring(s or "")
    return (
        s:gsub("([^%w%-_%.~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    )
end

local function http_get(url)
    local argv = {
        "curl",
        "-sS",
        "-L",
        "-A",
        USER_AGENT,
        "--max-time",
        tostring(HTTP_TIMEOUT),
        url,
    }
    local ok, stdout, stderr = util.run_cmd(argv)
    if not ok then
        return nil, (stderr ~= "" and stderr or stdout ~= "" and stdout or "curl failed") .. " (" .. url .. ")"
    end
    if not stdout or trim(stdout) == "" then
        return nil, "empty HTTP body from " .. url
    end
    return stdout, nil
end

local function parse_json(raw, what)
    local ok, data = pcall(wezterm.json_parse, raw or "")
    if not ok or type(data) ~= "table" then
        return nil, "unreadable " .. (what or "JSON") .. ": " .. tostring(raw):sub(1, 240)
    end
    return data, nil
end

local function place_label(parts)
    local out = {}
    for _, p in ipairs(parts) do
        if type(p) == "string" and trim(p) ~= "" then
            table.insert(out, trim(p))
        end
    end
    return table.concat(out, ", ")
end

local function geocode_zippopotam(zip, country)
    local compact = zip:gsub("%s+", "")
    local url = "https://api.zippopotam.us/" .. url_encode(country:lower()) .. "/" .. url_encode(compact)
    local raw, err = http_get(url)
    if not raw then
        return nil, err
    end
    local data, perr = parse_json(raw, "zippopotam")
    if not data then
        return nil, perr
    end
    local places = data.places
    if type(places) ~= "table" or type(places[1]) ~= "table" then
        return nil, "zip not found: " .. zip
    end
    local p = places[1]
    local lat = tonumber(p.latitude)
    local lon = tonumber(p.longitude)
    if not lat or not lon then
        return nil, "zip geocode missing coordinates: " .. zip
    end
    return {
        lat = lat,
        lon = lon,
        place = place_label({
            p["place name"],
            p["state abbreviation"] or p.state,
            data["country abbreviation"] or country,
        }),
        zip = tostring(data["post code"] or zip),
        country = tostring(data["country abbreviation"] or country),
    },
        nil
end

local function geocode_open_meteo(query, country)
    local url = "https://geocoding-api.open-meteo.com/v1/search?name="
        .. url_encode(query)
        .. "&count=1&language=en&format=json"
    if country and country ~= "" then
        url = url .. "&countryCode=" .. url_encode(country)
    end
    local raw, err = http_get(url)
    if not raw then
        return nil, err
    end
    local data, perr = parse_json(raw, "open-meteo geocoding")
    if not data then
        return nil, perr
    end
    local results = data.results
    if type(results) ~= "table" or type(results[1]) ~= "table" then
        return nil, "location not found: " .. query
    end
    local r = results[1]
    local lat = tonumber(r.latitude)
    local lon = tonumber(r.longitude)
    if not lat or not lon then
        return nil, "geocode missing coordinates: " .. query
    end
    return {
        lat = lat,
        lon = lon,
        place = place_label({ r.name, r.admin1, r.country_code or r.country }),
        zip = query,
        country = tostring(r.country_code or country or ""),
    },
        nil
end

local function geocode_nominatim(zip, country)
    local url = "https://nominatim.openstreetmap.org/search?postalcode="
        .. url_encode(zip)
        .. "&countrycodes="
        .. url_encode(country:lower())
        .. "&format=json&limit=1"
    local raw, err = http_get(url)
    if not raw then
        return nil, err
    end
    local data, perr = parse_json(raw, "nominatim")
    if not data then
        return nil, perr
    end
    local hit = data[1]
    if type(hit) ~= "table" then
        return nil, "zip not found: " .. zip
    end
    local lat = tonumber(hit.lat)
    local lon = tonumber(hit.lon)
    if not lat or not lon then
        return nil, "zip geocode missing coordinates: " .. zip
    end
    return {
        lat = lat,
        lon = lon,
        place = hit.display_name or zip,
        zip = zip,
        country = country,
    },
        nil
end

function M.geocode(zip, country)
    zip = normalize_zip(zip)
    country = normalize_country(country)
    if zip == "" then
        return nil, "empty zip"
    end
    local geo, err = geocode_zippopotam(zip, country)
    if geo then
        return geo, nil
    end
    local geo2, err2 = geocode_open_meteo(zip, country)
    if geo2 then
        return geo2, nil
    end
    local geo3, err3 = geocode_nominatim(zip, country)
    if geo3 then
        return geo3, nil
    end
    return nil, err3 or err2 or err or ("could not geocode " .. zip)
end

local function cache_matches(cache, zip, country)
    if type(cache) ~= "table" then
        return false
    end
    return normalize_zip(cache.zip) == normalize_zip(zip)
        and normalize_country(cache.country) == normalize_country(country)
        and tonumber(cache.lat)
        and tonumber(cache.lon)
end

function M.resolve_coords(config)
    local loc = M.resolved_location(config)
    if not loc.zip then
        return nil,
            "No zip set. Use @weather:zip (saved by the plugin) or weather = { zip = \"90210\" } in apply_to_config."
    end
    local store = loc.store or empty_store()
    if cache_matches(store.cache, loc.zip, loc.country) then
        return {
            zip = loc.zip,
            country = loc.country,
            units = loc.units,
            lat = tonumber(store.cache.lat),
            lon = tonumber(store.cache.lon),
            place = store.cache.place or loc.zip,
            from_plugin = loc.from_plugin,
        },
            nil
    end
    local geo, err = M.geocode(loc.zip, loc.country)
    if not geo then
        return nil, err
    end
    store.cache = {
        zip = loc.zip,
        country = loc.country,
        lat = geo.lat,
        lon = geo.lon,
        place = geo.place,
    }
    M.save_store(config, store)
    return {
        zip = loc.zip,
        country = loc.country,
        units = loc.units,
        lat = geo.lat,
        lon = geo.lon,
        place = geo.place,
        from_plugin = loc.from_plugin,
    },
        nil
end

--- Persist zip from the plugin. Pass zip nil/"clear"/"none" to drop the overlay (wezterm.lua zip applies).
function M.set_zip(config, zip_raw, country_raw)
    local store = M.load_store(config)
    local token = trim(zip_raw or "")
    if token == "" or token:lower() == "clear" or token:lower() == "none" then
        store.zip = nil
        store.country = nil
        store.cache = nil
        local ok, err = M.save_store(config, store)
        if not ok then
            return nil, err
        end
        return {
            zip = weather_opts(config).zip,
            country = normalize_country(weather_opts(config).country),
            cleared = true,
        },
            nil
    end
    local zip, country = M.parse_zip_input(token, country_raw or weather_opts(config).country)
    if not zip or zip == "" then
        return nil, "invalid zip"
    end
    local geo, err = M.geocode(zip, country)
    if not geo then
        return nil, err
    end
    store.zip = zip
    store.country = country
    store.cache = {
        zip = zip,
        country = country,
        lat = geo.lat,
        lon = geo.lon,
        place = geo.place,
    }
    local ok, werr = M.save_store(config, store)
    if not ok then
        return nil, werr
    end
    return {
        zip = zip,
        country = country,
        lat = geo.lat,
        lon = geo.lon,
        place = geo.place,
        cleared = false,
    },
        nil
end

local function use_imperial(units, country)
    if units == "imperial" then
        return true
    end
    if units == "metric" then
        return false
    end
    return normalize_country(country) == "US"
end

local function wmo_text(code)
    code = tonumber(code)
    if code == nil then
        return "Unknown"
    end
    return WMO[code] or ("WMO " .. tostring(code))
end

local function wind_dir(deg)
    deg = tonumber(deg)
    if deg == nil then
        return ""
    end
    local idx = math.floor((deg % 360) / 22.5 + 0.5) % 16
    return COMPASS[idx + 1] or ""
end

local function fmt_num(n, digits)
    n = tonumber(n)
    if n == nil then
        return "?"
    end
    return string.format("%." .. tostring(digits or 0) .. "f", n)
end

local function weekday(iso)
    -- iso YYYY-MM-DD → local weekday via os.time (date is civil local, close enough)
    local y, m, d = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then
        return tostring(iso or "")
    end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    if not t then
        return iso
    end
    return os.date("%a", t)
end

function M.fetch_forecast(coords)
    local imperial = use_imperial(coords.units, coords.country)
    local url = "https://api.open-meteo.com/v1/forecast?latitude="
        .. tostring(coords.lat)
        .. "&longitude="
        .. tostring(coords.lon)
        .. "&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,"
        .. "wind_speed_10m,wind_direction_10m,precipitation,cloud_cover"
        .. "&hourly=temperature_2m,precipitation_probability,weather_code"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max"
        .. "&forecast_days=7&timezone=auto"
    if imperial then
        url = url .. "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch"
    else
        url = url .. "&temperature_unit=celsius&wind_speed_unit=kmh&precipitation_unit=mm"
    end
    local raw, err = http_get(url)
    if not raw then
        return nil, err
    end
    local data, perr = parse_json(raw, "open-meteo forecast")
    if not data then
        return nil, perr
    end
    data._imperial = imperial
    return data, nil
end

local function temp_unit(imperial)
    return imperial and "°F" or "°C"
end

local function wind_unit(imperial)
    return imperial and "mph" or "km/h"
end

local function precip_unit(imperial)
    return imperial and "in" or "mm"
end

local function format_current(coords, data)
    local imperial = data._imperial
    local cur = data.current or {}
    local units = data.current_units or {}
    local tu = units.temperature_2m or temp_unit(imperial)
    local wu = units.wind_speed_10m or wind_unit(imperial)
    if wu == "mp/h" then
        wu = "mph"
    end
    local dir = wind_dir(cur.wind_direction_10m)
    local lines = {
        "Weather — " .. (coords.place or coords.zip) .. "  " .. (coords.zip or ""),
        string.format("%.2f, %.2f  ·  %s", coords.lat, coords.lon, data.timezone or ""),
        "",
        string.format(
            "Now  %s%s  %s",
            fmt_num(cur.temperature_2m, 0),
            tu,
            wmo_text(cur.weather_code)
        ),
        string.format(
            "Feels %s%s  ·  Humidity %s%%  ·  Wind %s %s%s  ·  Clouds %s%%",
            fmt_num(cur.apparent_temperature, 0),
            tu,
            fmt_num(cur.relative_humidity_2m, 0),
            fmt_num(cur.wind_speed_10m, 0),
            wu,
            dir ~= "" and (" " .. dir) or "",
            fmt_num(cur.cloud_cover, 0)
        ),
    }
    local precip = tonumber(cur.precipitation) or 0
    if precip > 0 then
        table.insert(
            lines,
            "Precip " .. fmt_num(precip, imperial and 2 or 1) .. " " .. precip_unit(imperial)
        )
    end
    return table.concat(lines, "\n")
end

local function format_hourly(data, hours)
    hours = hours or 6
    local hourly = data.hourly
    if type(hourly) ~= "table" or type(hourly.time) ~= "table" then
        return nil
    end
    local imperial = data._imperial
    local tu = (data.hourly_units and data.hourly_units.temperature_2m) or temp_unit(imperial)
    local now = (data.current and data.current.time) or ""
    local start = 1
    for i, t in ipairs(hourly.time) do
        if t >= now then
            start = i
            break
        end
    end
    local lines = { "", "Next hours" }
    local n = 0
    for i = start, #hourly.time do
        n = n + 1
        if n > hours then
            break
        end
        local stamp = hourly.time[i] or ""
        local hhmm = stamp:match("T(%d%d:%d%d)") or stamp
        local pop = hourly.precipitation_probability and hourly.precipitation_probability[i]
        table.insert(
            lines,
            string.format(
                "  %s  %s%s  %s  %s%%",
                hhmm,
                fmt_num(hourly.temperature_2m and hourly.temperature_2m[i], 0),
                tu,
                wmo_text(hourly.weather_code and hourly.weather_code[i]),
                fmt_num(pop, 0)
            )
        )
    end
    if n == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

local function format_daily(data, days)
    days = days or 7
    local daily = data.daily
    if type(daily) ~= "table" or type(daily.time) ~= "table" then
        return nil
    end
    local imperial = data._imperial
    local tu = (data.daily_units and data.daily_units.temperature_2m_max) or temp_unit(imperial)
    local lines = { "", "Forecast" }
    for i = 1, math.min(days, #daily.time) do
        local pop = daily.precipitation_probability_max and daily.precipitation_probability_max[i]
        table.insert(
            lines,
            string.format(
                "  %-3s  %s/%s%s  %s  %s%% precip",
                weekday(daily.time[i]),
                fmt_num(daily.temperature_2m_min and daily.temperature_2m_min[i], 0),
                fmt_num(daily.temperature_2m_max and daily.temperature_2m_max[i], 0),
                tu,
                wmo_text(daily.weather_code and daily.weather_code[i]),
                fmt_num(pop, 0)
            )
        )
    end
    return table.concat(lines, "\n")
end

function M.format_now(coords, data)
    local parts = { format_current(coords, data) }
    local hourly = format_hourly(data, 6)
    if hourly then
        table.insert(parts, hourly)
    end
    local today = format_daily(data, 2)
    if today then
        table.insert(parts, today)
    end
    table.insert(parts, "\nOpen-Meteo  ·  zip via @weather:zip")
    return table.concat(parts, "\n")
end

function M.format_forecast(coords, data)
    local parts = { format_current(coords, data) }
    local daily = format_daily(data, 7)
    if daily then
        table.insert(parts, daily)
    end
    table.insert(parts, "\nOpen-Meteo  ·  zip via @weather:zip")
    return table.concat(parts, "\n")
end

function M.collect_report(config, kind)
    local coords, err = M.resolve_coords(config)
    if not coords then
        return nil, err
    end
    local data, ferr = M.fetch_forecast(coords)
    if not data then
        return nil, ferr
    end
    if kind == "forecast" then
        return M.format_forecast(coords, data), nil
    end
    return M.format_now(coords, data), nil
end

function M.collect_attach(syn, config)
    local raw = syn:match("^weather:(.+)$") or syn
    if raw == "weather" or raw == "" then
        raw = "now"
    end
    if raw == "now" or raw == "current" then
        return M.collect_report(config, "now")
    elseif raw == "forecast" then
        return M.collect_report(config, "forecast")
    end
    return nil, "unknown @weather attach: " .. tostring(syn) .. " (try @weather:now or @weather:forecast)"
end

local function print_show(ai_pane, title, body)
    ui.begin_turn(ai_pane, os.date("%H:%M:%S") .. "  weather")
    ui.ai_print(ai_pane, title, "attach")
    ui.ai_print(ai_pane, body ~= "" and body or "(empty)", "plain")
end

local function prompt_line(window, pane, description, callback)
    window:perform_action(
        act.PromptInputLine({
            description = description,
            action = wezterm.action_callback(function(win, p, line)
                if line == nil then
                    return
                end
                callback(win, p, trim(line))
            end),
        }),
        pane
    )
end

local function show_report(ctx, kind)
    local body, err = M.collect_report(ctx.config, kind)
    if err then
        ui.ai_print(ctx.ai_pane, err, "error")
        return
    end
    print_show(ctx.ai_pane, kind == "forecast" and "@weather:forecast" or "@weather:now", body)
end

local ACTIONS = {}
local ACTION_ORDER = {}

local function add_action(a)
    ACTIONS[a.id] = a
    table.insert(ACTION_ORDER, a.id)
    if a.aliases then
        for _, al in ipairs(a.aliases) do
            ACTIONS[al] = a
        end
    end
end

add_action({
    id = "now",
    label = "now — current conditions + next hours (Open-Meteo)",
    kind = "show",
    attach = true,
    aliases = { "current" },
    run = function(ctx)
        show_report(ctx, "now")
    end,
})

add_action({
    id = "forecast",
    label = "forecast — 7-day (Open-Meteo)",
    kind = "show",
    attach = true,
    run = function(ctx)
        show_report(ctx, "forecast")
    end,
})

add_action({
    id = "zip",
    label = "zip — set postal code (saved by wezai, not wezterm.lua)",
    kind = "shell",
    run = function(ctx)
        local function apply(raw)
            if raw == nil then
                return
            end
            if trim(raw) == "" then
                return
            end
            local loc, err = M.set_zip(ctx.config, raw)
            local ap = ui.ensure_ai_pane(ctx.window, ctx.pane, ctx.config)
            if err then
                ui.ai_print(ap, err, "error")
                return
            end
            if loc.cleared then
                local fallback = loc.zip and tostring(loc.zip) or "(none in wezterm.lua)"
                ui.ai_print(
                    ap,
                    "Cleared plugin zip overlay. wezterm.lua weather.zip = " .. fallback,
                    "success"
                )
                return
            end
            ui.ai_print(
                ap,
                "Saved zip "
                    .. loc.zip
                    .. " ("
                    .. loc.country
                    .. ") → "
                    .. (loc.place or "")
                    .. "\nPersisted in "
                    .. M.store_path(ctx.config)
                    .. " (overrides weather.zip until you @weather:zip clear).",
                "success"
            )
        end
        local from_extra = trim(ctx.extra or "")
        if from_extra ~= "" then
            apply(from_extra)
            return
        end
        local loc = M.resolved_location(ctx.config)
        local hint = loc.zip and ("current " .. loc.zip) or "not set"
        prompt_line(
            ctx.window,
            ctx.pane,
            "ZIP / postal code (" .. hint .. " — e.g. 90210 or 90210, US; 'clear' drops overlay)",
            apply
        )
    end,
})

add_action({
    id = "where",
    label = "where — show configured zip / resolved place",
    kind = "show",
    run = function(ctx)
        local loc = M.resolved_location(ctx.config)
        local lines = {
            "weather.zip (wezterm.lua) = " .. tostring(weather_opts(ctx.config).zip or "(unset)"),
            "plugin overlay zip       = " .. tostring(loc.store and loc.store.zip or "(none)"),
            "effective zip            = " .. tostring(loc.zip or "(not set)"),
            "country                  = " .. tostring(loc.country),
            "units                    = " .. tostring(loc.units),
            "store                    = " .. M.store_path(ctx.config),
        }
        if loc.zip then
            local coords, err = M.resolve_coords(ctx.config)
            if coords then
                table.insert(lines, "place                    = " .. tostring(coords.place))
                table.insert(lines, string.format("coords                   = %.4f, %.4f", coords.lat, coords.lon))
            elseif err then
                table.insert(lines, "geocode                  = " .. err)
            end
        else
            table.insert(lines, "Hint: @weather:zip 90210  or  weather = { zip = \"90210\" }")
        end
        print_show(ctx.ai_pane, "@weather:where", table.concat(lines, "\n"))
    end,
})

function M.list_actions()
    local list = {}
    for _, id in ipairs(ACTION_ORDER) do
        local a = ACTIONS[id]
        if a and a.id == id then
            table.insert(list, a)
        end
    end
    return list
end

function M.get_action(id)
    return ACTIONS[id]
end

-- Returns nil (not weather), or { mode="picker"|"run"|"attach", id?, extra? }
function M.parse_line(line)
    local token = trim(line or "")
    if token == "@weather" or token == "@weather:" then
        return { mode = "picker" }
    end
    local rest_only = token:match("^@weather%s+(.+)$")
    if rest_only then
        return { mode = "attach", id = "now" }
    end
    local id, rest = token:match("^@weather:([%w%-]+)%s*(.-)%s*$")
    if not id then
        return nil
    end
    local action = ACTIONS[id]
    if not action then
        return nil
    end
    rest = trim(rest)
    if rest == "" then
        return { mode = "run", id = action.id }
    end
    if action.id == "zip" then
        return { mode = "run", id = action.id, extra = rest }
    end
    if action.attach then
        return { mode = "attach", id = action.id }
    end
    return { mode = "run", id = action.id, extra = rest }
end

function M.run_action(window, pane, config, id, extra)
    local shell_pane = ui.shell_pane_for(window, pane)
    local ai_pane = ui.ensure_ai_pane(window, shell_pane, config)
    local action = ACTIONS[id]
    if not action then
        ui.ai_print(ai_pane, "Unknown @weather:" .. tostring(id) .. " — try @weather for the picker", "error")
        return
    end
    action.run({
        window = window,
        pane = shell_pane,
        ai_pane = ai_pane,
        config = config,
        extra = extra,
    })
end

function M.open_picker(window, pane, config)
    require("palette").show(window, pane, config, { scope = "weather" })
end

return M
