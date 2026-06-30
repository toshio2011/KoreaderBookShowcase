local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local DocumentRegistry = require("document/documentregistry")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local ImageViewer = require("ui/widget/imageviewer")
local TitleBar = require("ui/widget/titlebar")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Font = require("ui/font")
local Size = require("ui/size")
local Screen = require("device").screen
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local BookShowcase = WidgetContainer:extend{
    name = "bookshowcase",
}

local PLUGIN_VERSION = "1.1.0"
local PLUGIN_AUTHOR = "MsNooYooL"


-- Scrollable book-card viewer.  It reuses KOReader's ImageViewer for safe
-- cover handling, but can also run as a centered popup instead of full screen.
local ShowcaseViewer = ImageViewer:extend{
    showcase_caption = nil,
    showcase_cover_height_ratio = 0.24,
    showcase_font_size = nil,
    showcase_text_alignment = "left",
    showcase_bgcolor = nil,
    showcase_fgcolor = nil,
    showcase_popup_size = "large",
    showcase_border_size = 1,
    showcase_lock_cover_zoom = true,
    showcase_presentation_layout = "balanced",
    _showcase_caption_widget = nil,
    _showcase_header_container = nil,
}

local function popupDimensions(size)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local width_ratio, height_ratio

    if size == "small" then
        width_ratio, height_ratio = 0.70, 0.68
    elseif size == "medium" then
        width_ratio, height_ratio = 0.82, 0.80
    elseif size == "near_full" then
        width_ratio, height_ratio = 0.96, 0.94
    elseif size == "fullscreen" then
        width_ratio, height_ratio = 1.00, 1.00
    else -- large
        width_ratio, height_ratio = 0.91, 0.89
    end

    return math.floor(screen_w * width_ratio), math.floor(screen_h * height_ratio)
end

function ShowcaseViewer:_setShowcaseDimensions()
    local size = self.showcase_popup_size or "large"

    if size == "fullscreen" then
        self.fullscreen = true
        self.width = Screen:getWidth()
        self.height = Screen:getHeight()
    else
        self.fullscreen = false
        self.width, self.height = popupDimensions(size)
    end
end

function ShowcaseViewer:_applyTitleBarColours()
    if not self.title_bar then
        return
    end

    local bg = self.showcase_bgcolor or Blitbuffer.COLOR_WHITE
    local fg = self.showcase_fgcolor or Blitbuffer.COLOR_BLACK

    -- TitleBar itself is transparent, but its child widgets honour these
    -- colours on current KOReader builds.  The main frame supplies the rest
    -- of the coloured header background.
    self.title_bar.background = bg
    if self.title_bar.title_widget then
        self.title_bar.title_widget.bgcolor = bg
        self.title_bar.title_widget.fgcolor = fg
    end
    if self.title_bar.subtitle_widget then
        self.title_bar.subtitle_widget.bgcolor = bg
        self.title_bar.subtitle_widget.fgcolor = fg
    end
    if self.title_bar.right_button then
        self.title_bar.right_button.background = bg
        self.title_bar.right_button.bgcolor = bg
        self.title_bar.right_button.fgcolor = fg
    end
end

function ShowcaseViewer:_rebuildShowcaseTitleBar()
    if not self.with_title_bar then
        return
    end

    -- Rebuild the complete header wrapper.  TitleBar itself does not paint a
    -- background, so the FrameContainer is what gives the header the same
    -- colour as the selected card background.
    if self._showcase_header_container then
        self._showcase_header_container:free()
        self._showcase_header_container = nil
        self.title_bar = nil
    elseif self.title_bar then
        self.title_bar:free()
        self.title_bar = nil
    end

    self.title_bar = TitleBar:new{
        width = self.width,
        fullscreen = self.fullscreen,
        align = "left",
        title = self.title_text or "",
        -- A single-line TextWidget is transparent.  The earlier multiline
        -- TextBoxWidget painted a white rectangle behind the title.
        title_multilines = false,
        title_shrink_font_to_fit = true,
        with_bottom_line = true,
        bottom_line_color = self.showcase_fgcolor or Blitbuffer.COLOR_BLACK,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    self:_applyTitleBarColours()

    self._showcase_header_container = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = self.showcase_bgcolor or Blitbuffer.COLOR_WHITE,
        self.title_bar,
    }
end

function ShowcaseViewer:init()
    -- We add the caption ourselves beneath the cover.
    self.caption = nil
    ImageViewer.init(self)

    -- ImageViewer normally fixes non-fullscreen windows to a single size.
    -- Rebuild the dependent title bar after applying the requested popup size.
    self:_setShowcaseDimensions()
    self:_rebuildShowcaseTitleBar()
    self:update()
end

function ShowcaseViewer:_cleanShowcaseCaptionWidget()
    if self._showcase_caption_widget then
        self._showcase_caption_widget:free()
        self._showcase_caption_widget = nil
    end
end

function ShowcaseViewer:update()
    self:_setShowcaseDimensions()
    self.main_frame.background = self.showcase_bgcolor or Blitbuffer.COLOR_WHITE
    self:_applyTitleBarColours()

    self:_clean_image_wg()
    self:_cleanShowcaseCaptionWidget()

    local orig_dimen = self.main_frame.dimen

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    if self.with_title_bar then
        table.insert(self.frame_elements, self._showcase_header_container or self.title_bar)
    end

    -- Keep the cover at a predictable size. The metadata below is scrollable.
    local title_height = self.frame_elements:getSize().h
    local available_height = self.height - title_height
    local minimum_caption_height = Screen:scaleBySize(170)
    local cover_height = math.floor(available_height * self.showcase_cover_height_ratio)

    if available_height - cover_height < minimum_caption_height then
        cover_height = math.max(Screen:scaleBySize(130), available_height - minimum_caption_height)
    end

    self.img_container_h = cover_height
    self:_new_image_wg()
    table.insert(self.frame_elements, self.image_container)

    local caption = self.showcase_caption or ""
    if caption ~= "" then
        local caption_height = math.max(
            Screen:scaleBySize(110),
            available_height - cover_height - 2 * Size.padding.small
        )
        local caption_width = self.width - 2 * self.image_padding

        self._showcase_caption_widget = ScrollTextWidget:new{
            text = caption,
            face = Font:getFace(
                "cfont",
                self.showcase_font_size or Screen:scaleBySize(12)
            ),
            width = caption_width,
            height = caption_height,
            dialog = self,
            scroll_by_pan = true,
            alignment = self.showcase_text_alignment or "left",
            fgcolor = self.showcase_fgcolor or Blitbuffer.COLOR_BLACK,
        }

        if self._showcase_caption_widget.text_widget then
            self._showcase_caption_widget.text_widget.bgcolor = self.showcase_bgcolor or Blitbuffer.COLOR_WHITE
            self._showcase_caption_widget.text_widget.fgcolor = self.showcase_fgcolor or Blitbuffer.COLOR_BLACK
            if self._showcase_caption_widget.text_widget.update then
                self._showcase_caption_widget.text_widget:update()
            end
        end

        local caption_container = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = caption_height,
            },
            self._showcase_caption_widget,
        }

        table.insert(self.frame_elements, caption_container)
    end

    if self.buttons_visible then
        local scale_btn = self.button_table:getButtonById("scale")
        scale_btn:setText(
            self._scale_to_fit and _("Original size") or _("Scale"),
            scale_btn.width
        )

        local rotate_btn = self.button_table:getButtonById("rotate")
        rotate_btn:setText(
            self.rotated and _("No rotation") or _("Rotate"),
            rotate_btn.width
        )

        table.insert(self.frame_elements, self.button_container)
    end

    self.frame_elements:resetLayout()
    self.main_frame.radius = not self.fullscreen and Screen:scaleBySize(12) or nil
    -- A subtly raised popup frame. Unsupported attributes are safely ignored
    -- on older KOReader builds.
    self.main_frame.bordersize = not self.fullscreen and Screen:scaleBySize(self.showcase_border_size or 1) or 0
    self.main_frame.bordercolor = self.showcase_fgcolor or Blitbuffer.COLOR_BLACK

    UIManager:setDirty(self, function()
        local update_region = self.main_frame.dimen:combine(orig_dimen)
        return "ui", update_region, true
    end)
end

-- A stationary long press on the opened showcase exposes book-specific actions.
-- We keep ImageViewer's normal panning behaviour when the finger moves.
-- Locking cover zoom avoids accidental scaling while scrolling the card.
-- The toggle is intentionally limited to zoom gestures; pan/scroll behaviour is unchanged.
function ShowcaseViewer:onPinch(...)
    if self.showcase_lock_cover_zoom then
        return true
    end
    if ImageViewer.onPinch then
        return ImageViewer.onPinch(self, ...)
    end
    return true
end

function ShowcaseViewer:onDoubleTap(...)
    if self.showcase_lock_cover_zoom then
        return true
    end
    if ImageViewer.onDoubleTap then
        return ImageViewer.onDoubleTap(self, ...)
    end
    return true
end

function ShowcaseViewer:onHold(_, ges)
    self._showcase_hold_x = ges.pos.x
    self._showcase_hold_y = ges.pos.y
    self._showcase_hold_active = true
    self._panning = true
    self._pan_relative_x = ges.pos.x
    self._pan_relative_y = ges.pos.y
    return true
end

function ShowcaseViewer:onHoldRelease(_, ges)
    local start_x = self._showcase_hold_x
    local start_y = self._showcase_hold_y
    local threshold = self.pan_threshold or Screen:scaleBySize(5)

    self._showcase_hold_active = false

    if start_x and start_y then
        local moved_x = ges.pos.x - start_x
        local moved_y = ges.pos.y - start_y

        if math.abs(moved_x) < threshold and math.abs(moved_y) < threshold then
            self._panning = false
            self._showcase_hold_x = nil
            self._showcase_hold_y = nil

            if self.showcase_action_callback then
                local callback = self.showcase_action_callback
                -- Opening a dialog during Android's ImageViewer hold-release
                -- can race native gesture teardown. Run it next UI tick.
                UIManager:nextTick(function()
                    callback(self)
                end)
                return true
            end
        end
    end

    self._showcase_hold_x = nil
    self._showcase_hold_y = nil
    return ImageViewer.onHoldRelease(self, _, ges)
end

local SETTINGS_KEY = "bookshowcase_settings"
local PREVIEW_BOOK_KEY = "bookshowcase_preview_book"
local STATS_DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local BACKUP_FILE = DataStorage:getSettingsDir() .. "/bookshowcase_settings_backup.lua"

local FIELD_KEYS = {
    "title",
    "author",
    "series",
    "series_index",
    "language",
    "keywords",
    "description",
    "pages",
    "progress",
    "status",
    "status_badge",
    "finished_date",
    "stat_time",
    "stat_pages",
    "stat_days",
    "reading_pace",
    "stat_highlights",
    "stat_notes",
    "stat_last_open",
    "rating",
    "review",
    "footer",
}

local FIELD_LABELS = {
    title = _("Title"),
    author = _("Author"),
    series = _("Series"),
    series_index = _("Series number"),
    language = _("Language"),
    keywords = _("Tags"),
    description = _("Description"),
    pages = _("Pages"),
    progress = _("Reading progress"),
    status = _("Reading status"),
    status_badge = _("Status badge"),
    finished_date = _("Finished date"),
    stat_time = _("Reading time"),
    stat_pages = _("Pages read"),
    stat_days = _("Reading days"),
    reading_pace = _("Reading pace"),
    stat_highlights = _("Highlights"),
    stat_notes = _("Notes"),
    stat_last_open = _("Last opened"),
    rating = _("Rating"),
    review = _("Review"),
    footer = _("Footer"),
}

local function defaultOrder()
    return {
        "title",
        "author",
        "series",
        "series_index",
        "language",
        "keywords",
        "description",
        "pages",
        "progress",
        "status",
        "stat_time",
        "stat_pages",
        "stat_days",
        "stat_highlights",
        "stat_notes",
        "stat_last_open",
        "rating",
        "review",
        "footer",
    }
end

local function defaultSettings()
    return {
        show_title_bar = true,
        show_labels = false,

        show_title = false,
        show_author = true,
        show_series = false,
        show_series_index = false,
        show_language = false,
        show_keywords = false,
        show_description = false,
        show_pages = false,
        show_progress = false,
        show_status = false,
        show_status_badge = true,
        show_finished_date = false,

        show_stat_time = false,
        show_stat_pages = false,
        show_stat_days = false,
        show_reading_pace = false,
        show_stat_highlights = false,
        show_stat_notes = false,
        show_stat_last_open = false,

        show_rating = true,
        show_review = true,
        show_footer = true,

        description_length = "medium",
        review_length = "full",
        spacing = "normal",
        footer_text = "#BookShowcase",

        cover_size = "medium",
        card_density = "compact",
        show_section_headers = true,
        show_footer_divider = true,
        custom_colors_enabled = false,
        custom_bg_color = "#FFFFFF",
        custom_fg_color = "#000000",
        background_theme = "paper",
        cover_zoom_locked = true,
        presentation_layout = "balanced",
        description_read_more = true,
        show_completion_badge = true,
        hide_empty_sections = true,
        accent_style = "line",
        card_style = "soft",
        text_alignment = "left",
        social_card_mode = false,

        template = "classic",
        review_style = "quote",
        hide_unknown_author = true,
        social_review_short = true,
        footer_position = "bottom",
        popup_size = "large",
        background_strength = "normal",
        popup_border = "thin",

        -- Text-only visual options. These do not create extra graphics widgets.
        rating_style = "stars",
        section_icons = false,
        footer_style = "simple",
        auto_finished_footer = false,

        saved_presets = {},

        field_order = defaultOrder(),
    }
end

local function ensureOrder(settings)
    if type(settings.field_order) ~= "table" then
        settings.field_order = defaultOrder()
        return
    end

    local clean = {}
    local seen = {}

    for _, key in ipairs(settings.field_order) do
        if FIELD_LABELS[key] and not seen[key] then
            table.insert(clean, key)
            seen[key] = true
        end
    end

    for _, key in ipairs(FIELD_KEYS) do
        if not seen[key] then
            table.insert(clean, key)
        end
    end

    settings.field_order = clean
end

local function getSettings()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    local defaults = defaultSettings()

    for key, value in pairs(defaults) do
        if settings[key] == nil then
            settings[key] = value
        end
    end

    -- Legacy Modern/Elegant/Minimal styles are retired; the popup now uses one clean Soft Card design.
    settings.card_style = "soft"

    ensureOrder(settings)

    return settings
end

local function saveSettings(settings)
    ensureOrder(settings)

    G_reader_settings:saveSetting(SETTINGS_KEY, settings)

    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end


-- Settings backup is stored alongside KOReader's settings so it remains
-- available to this plugin without needing storage-permission assumptions.
local function serializeLua(value, indent)
    indent = indent or ""
    local next_indent = indent .. "  "
    local value_type = type(value)

    if value_type == "nil" then
        return "nil"
    elseif value_type == "boolean" or value_type == "number" then
        return tostring(value)
    elseif value_type == "string" then
        return string.format("%q", value)
    elseif value_type ~= "table" then
        return "nil"
    end

    local keys = {}
    for key, _ in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    if #keys == 0 then
        return "{}"
    end

    local lines = { "{" }
    for _, key in ipairs(keys) do
        local key_text
        if type(key) == "string" and key:match("^[%a_][%w_]*$") then
            key_text = key
        else
            key_text = "[" .. serializeLua(key) .. "]"
        end
        table.insert(lines, next_indent .. key_text .. " = " .. serializeLua(value[key], next_indent) .. ",")
    end
    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
end

local function saveSettingsBackup()
    local file, err = io.open(BACKUP_FILE, "w")
    if not file then
        return false, err or "Cannot write backup file."
    end

    file:write("-- Book Showcase settings backup\n")
    file:write("-- Restore only through Book Showcase settings.\n")
    file:write("return ")
    file:write(serializeLua(getSettings()))
    file:write("\n")
    file:close()
    return true
end

local function loadSettingsBackup()
    if lfs.attributes(BACKUP_FILE, "mode") ~= "file" then
        return nil, "No backup file found yet."
    end

    local loader, load_err = loadfile(BACKUP_FILE)
    if not loader then
        return nil, load_err or "Cannot read backup file."
    end

    local ok, restored = pcall(loader)
    if not ok or type(restored) ~= "table" then
        return nil, "Backup file is not valid."
    end

    ensureOrder(restored)
    return restored
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepCopy(item)
    end
    return copy
end

local function presetNames(settings)
    local names = {}
    local presets = settings.saved_presets or {}

    for name, _ in pairs(presets) do
        table.insert(names, name)
    end

    table.sort(names)
    return names
end

local function makePresetFromSettings(settings)
    local preset = deepCopy(settings)
    preset.saved_presets = nil
    return preset
end

local function applySavedPreset(settings, preset)
    local saved_presets = settings.saved_presets or {}
    local fresh = defaultSettings()

    for key, value in pairs(preset or {}) do
        if key ~= "saved_presets" then
            fresh[key] = deepCopy(value)
        end
    end

    fresh.saved_presets = saved_presets
    ensureOrder(fresh)
    return fresh
end

local function cleanText(value)
    if value == nil then
        return nil
    end

    value = tostring(value)

    if value == "" or value == "N/A" then
        return nil
    end

    return value
end

local function textOrDefault(value, fallback)
    return cleanText(value) or fallback
end

local function fileTitle(file)
    local _, filename = util.splitFilePathName(file)

    if not filename then
        return _("Unknown title")
    end

    return filename:gsub("%.[^%.]+$", "")
end

local function ratingStars(rating, style)
    rating = tonumber(rating) or 0

    if rating > 5 then
        rating = 5
    end

    local filled, empty = "★", "☆"
    if style == "hearts" then
        filled, empty = "♥", "♡"
    elseif style == "dots" then
        filled, empty = "●", "○"
    end

    if rating < 1 then
        return string.rep(empty, 5)
    end

    return string.rep(filled, rating) .. string.rep(empty, 5 - rating)
end

local function onOff(value)
    return value and _("On") or _("Off")
end

local function truncateText(text, max_chars)
    text = tostring(text or "")

    if #text <= max_chars then
        return text
    end

    return text:sub(1, max_chars) .. "..."
end

local function lengthLabel(mode)
    if mode == "short" then
        return _("Short")
    elseif mode == "medium" then
        return _("Medium")
    end

    return _("Full")
end

local function formatLength(text, mode)
    if mode == "short" then
        return truncateText(text, 120)
    elseif mode == "medium" then
        return truncateText(text, 300)
    end

    return text
end

local function spacingLabel(mode)
    if mode == "compact" then
        return _("Compact")
    elseif mode == "spacious" then
        return _("Spacious")
    end

    return _("Normal")
end

local function spacingValue(mode)
    if mode == "compact" then
        return "\n"
    elseif mode == "spacious" then
        return "\n\n\n"
    end

    return "\n\n"
end

local function isVisible(settings, field)
    return settings["show_" .. field] == true
end

local function getVisibleFields(settings)
    local active_fields = {}

    for _, field in ipairs(settings.field_order) do
        if isVisible(settings, field) then
            table.insert(active_fields, field)
        end
    end

    return active_fields
end

local function visibleOrderText(settings)
    local names = {}

    for _, field in ipairs(getVisibleFields(settings)) do
        table.insert(names, FIELD_LABELS[field] or field)
    end

    if #names == 0 then
        return _("No metadata is enabled")
    end

    return table.concat(names, " → ")
end

local function moveVisibleField(settings, field, direction)
    local visible = getVisibleFields(settings)
    local visible_index

    for i, key in ipairs(visible) do
        if key == field then
            visible_index = i
            break
        end
    end

    if not visible_index then
        return
    end

    local new_visible_index = visible_index + direction

    if new_visible_index < 1 or new_visible_index > #visible then
        return
    end

    local other_field = visible[new_visible_index]
    local field_index
    local other_index

    for i, key in ipairs(settings.field_order) do
        if key == field then
            field_index = i
        elseif key == other_field then
            other_index = i
        end
    end

    if field_index and other_index then
        settings.field_order[field_index], settings.field_order[other_index] =
            settings.field_order[other_index], settings.field_order[field_index]
    end
end

local function formatDuration(seconds)
    seconds = tonumber(seconds) or 0

    if seconds <= 0 then
        return nil
    end

    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)

    if hours > 0 and minutes > 0 then
        return string.format("%dh %dm", hours, minutes)
    elseif hours > 0 then
        return string.format("%dh", hours)
    end

    return string.format("%dm", math.max(1, minutes))
end

local function formatDate(timestamp)
    timestamp = tonumber(timestamp)

    if not timestamp or timestamp <= 0 then
        return nil
    end

    return os.date("%d %b %Y", timestamp)
end


local function finishedFooterText(summary)
    local finished_at = summary.finish_time
        or summary.finished_time
        or summary.time_finished
        or summary.end_time
        or summary.completed_time
    local finished_date = formatDate(finished_at)

    if finished_date then
        return _("Finished on ") .. finished_date
    end

    return _("Finished reading")
end


local function completionDateText(summary)
    local finished_at = summary.finish_time
        or summary.finished_time
        or summary.time_finished
        or summary.end_time
        or summary.completed_time

    return formatDate(finished_at)
end

local function statusBadgeText(raw_status, status)
    if raw_status == "complete" then
        return "[ " .. _("FINISHED") .. " ]"
    elseif raw_status == "reading" then
        return "[ " .. _("READING") .. " ]"
    elseif raw_status == "abandoned" then
        return "[ " .. _("ON HOLD") .. " ]"
    elseif status and status ~= "" then
        return "[ " .. status:upper() .. " ]"
    end

    return nil
end

local function readingPaceText(stats)
    local pages = tonumber(stats and stats.total_read_pages) or 0
    local days = tonumber(stats and stats.days) or 0

    if pages <= 0 or days <= 0 then
        return nil
    end

    local pace = pages / days

    if pace >= 10 then
        return string.format("%d pages/day", math.floor(pace + 0.5))
    elseif pace >= 1 then
        return string.format("%.1f pages/day", pace)
    end

    return string.format("%.2f pages/day", pace)
end

local function appendUniqueFooterLine(existing, addition)
    if not addition or addition == "" then
        return existing
    end
    if not existing or existing == "" then
        return addition
    end
    if existing:find(addition, 1, true) then
        return existing
    end
    return existing .. "\n" .. addition
end

local function getProgressText(doc_settings, summary)
    local value =
        summary.percent_finished
        or summary.progress
        or doc_settings:readSetting("percent_finished")
        or doc_settings:readSetting("book_percent_finished")

    value = tonumber(value)

    if not value then
        return nil
    end

    if value <= 1 then
        value = value * 100
    end

    if value < 0 then
        return nil
    end

    if value > 100 then
        value = 100
    end

    return string.format("%d%% read", math.floor(value + 0.5))
end


local function coverSizeLabel(size)
    if size == "small" then
        return _("Small")
    elseif size == "large" then
        return _("Large")
    elseif size == "very_large" then
        return _("Very large")
    elseif size == "huge" then
        return _("Huge")
    end

    return _("Medium")
end

local function coverHeightRatio(size)
    if size == "small" then
        return 0.20
    elseif size == "large" then
        return 0.30
    elseif size == "very_large" then
        return 0.38
    elseif size == "huge" then
        return 0.46
    end

    return 0.24
end

local function popupSizeLabel(size)
    if size == "small" then
        return _("Small popup")
    elseif size == "medium" then
        return _("Medium popup")
    elseif size == "near_full" then
        return _("Near full screen")
    elseif size == "fullscreen" then
        return _("Full screen")
    end

    return _("Large popup")
end

local function backgroundThemeLabel(theme)
    if theme == "warm" then
        return _("Warm paper")
    elseif theme == "slate" then
        return _("Slate")
    elseif theme == "night" then
        return _("Night")
    elseif theme == "custom" then
        return _("Custom colours")
    end
    return _("Paper")
end

local function presentationLayoutLabel(layout)
    if layout == "cover_focus" then
        return _("Cover focus")
    elseif layout == "details_focus" then
        return _("Details focus")
    end
    return _("Balanced")
end

local function coverZoomLabel(locked)
    return locked and _("Locked") or _("Unlocked")
end

local function backgroundStrengthLabel(strength)
    if strength == "soft" then
        return _("Soft")
    elseif strength == "solid" then
        return _("Solid")
    end

    return _("Normal")
end

local function popupBorderLabel(border)
    if border == "none" then
        return _("None")
    elseif border == "medium" then
        return _("Medium")
    elseif border == "thick" then
        return _("Thick")
    end

    return _("Thin")
end

local function popupBorderSize(border)
    if border == "none" then
        return 0
    elseif border == "medium" then
        return 2
    elseif border == "thick" then
        return 3
    end

    return 1
end

local function densityLabel(density)
    if density == "normal" then
        return _("Normal")
    elseif density == "spacious" then
        return _("Spacious")
    end

    return _("Compact")
end

local function densityFontSize(density)
    if density == "normal" then
        return Screen:scaleBySize(13)
    elseif density == "spacious" then
        return Screen:scaleBySize(14)
    end

    return Screen:scaleBySize(12)
end

local function sectionGap(density)
    if density == "spacious" then
        return "\n\n"
    elseif density == "normal" then
        return "\n"
    end

    return "\n"
end

local function accentLabel(accent)
    if accent == "star" then
        return _("Star")
    elseif accent == "dot" then
        return _("Dot")
    elseif accent == "bold" then
        return _("Bold")
    elseif accent == "none" then
        return _("None")
    end

    return _("Line")
end

local function cardStyleLabel(style)
    return _("Soft Card")
end

local function alignmentLabel(alignment)
    if alignment == "center" then
        return _("Centre")
    end

    return _("Left")
end

local function templateLabel(template)
    if template == "stats" then
        return _("Stats Card")
    elseif template == "review" then
        return _("Review Focus")
    elseif template == "full" then
        return _("Full Metadata")
    elseif template == "social" then
        return _("Minimal Social")
    elseif template == "finished" then
        return _("Finished Book")
    end

    return _("Classic Card")
end

local function ratingStyleLabel(style)
    if style == "hearts" then
        return _("Hearts")
    elseif style == "dots" then
        return _("Dots")
    end
    return _("Stars")
end

local function footerStyleLabel(style)
    if style == "framed" then
        return _("Framed")
    elseif style == "minimal" then
        return _("Minimal")
    end
    return _("Simple")
end

local function reviewStyleLabel(style)
    if style == "plain" then
        return _("Plain")
    elseif style == "framed" then
        return _("Framed quote")
    end

    return _("Quote")
end

local function footerPositionLabel(position)
    if position == "below_review" then
        return _("Below review")
    end

    return _("Bottom of card")
end

local function activeReviewText(settings, review)
    if not review or review == "" then
        return nil
    end

    if settings.social_card_mode and settings.social_review_short then
        return truncateText(review, 150)
    end

    return review
end

local function styledReview(settings, review)
    review = activeReviewText(settings, review)

    if not review then
        return nil
    end

    if settings.review_style == "plain" then
        return review
    end

    -- Keep review text clean and readable. KOReader's basic text widget does
    -- not support a true rounded box, so quotation marks are the least cluttered style.
    return "“" .. review .. "”"
end

-- A favourite quote is entered manually by the reader. This deliberately does
-- not scrape highlights: KOReader highlight storage differs by document type
-- and a manual quote remains reliable, simple and privacy-friendly.
local function styledFavouriteQuote(quote)
    if not quote or quote == "" then
        return nil
    end
    return "“" .. quote .. "”"
end

local function themePrefix(settings)
    if settings.accent_style == "star" then
        return "★ "
    elseif settings.accent_style == "dot" then
        return "• "
    elseif settings.accent_style == "bold" then
        return "— "
    end

    return ""
end

local function sectionHeader(settings, text)
    if not settings.show_section_headers or settings.social_card_mode then
        return nil
    end

    local icon = settings.section_icons and "✦ " or ""

    if settings.accent_style == "none" then
        return icon .. text
    elseif settings.accent_style == "line" then
        return icon .. text .. "\n────────"
    end

    return icon .. themePrefix(settings) .. text
end

local function footerDivider(settings)
    return "────────"
end

-- No decorative filler in compact mode: it keeps the popup calm and uncluttered.
local function compactAccent(settings)
    return nil
end

-- Accepts colours in #RRGGBB or RRGGBB format.
local function normalizeHexColor(value)
    if value == nil then
        return nil
    end

    local hex = tostring(value):gsub("%s+", "")

    if hex:sub(1, 1) == "#" then
        hex = hex:sub(2)
    end

    if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
        return nil
    end

    return "#" .. hex:upper()
end

local function hexToColor(hex, fallback)
    hex = normalizeHexColor(hex)

    if not hex then
        return fallback
    end

    return Blitbuffer.ColorRGB32(
        tonumber(hex:sub(2, 3), 16),
        tonumber(hex:sub(4, 5), 16),
        tonumber(hex:sub(6, 7), 16),
        255
    )
end

-- Canvas colours used by the showcase viewer. Default is always light.
-- KOReader's normal FrameContainer background is opaque. "Background strength"
-- safely changes how strongly the chosen colour is tinted toward white; it
-- does not rely on unsupported alpha transparency.
local function blendHexWithWhite(hex, ratio)
    hex = normalizeHexColor(hex) or "#FFFFFF"
    ratio = math.max(0, math.min(1, tonumber(ratio) or 1))

    local function blend(channel)
        local value = tonumber(hex:sub(channel, channel + 1), 16) or 255
        return math.floor(255 + (value - 255) * ratio + 0.5)
    end

    return string.format("#%02X%02X%02X", blend(2), blend(4), blend(6))
end

local function themeColors(settings)
    local themes = {
        paper = { bg = "#FFFFFF", fg = "#000000" },
        warm = { bg = "#F5EFE4", fg = "#241D17" },
        slate = { bg = "#E8EDF0", fg = "#172026" },
        night = { bg = "#202225", fg = "#F5F5F5" },
    }
    local selected = themes[settings.background_theme] or themes.paper
    local bg_hex = selected.bg
    local fg_hex = selected.fg

    -- Existing custom colour controls keep priority, so previously saved setups
    -- continue to look exactly as the user configured them.
    if settings.custom_colors_enabled or settings.background_theme == "custom" then
        bg_hex = settings.custom_bg_color or bg_hex
        fg_hex = settings.custom_fg_color or fg_hex
    end

    local ratio = 0.72
    if settings.background_strength == "soft" then
        ratio = 0.42
    elseif settings.background_strength == "solid" then
        ratio = 1.00
    end

    return hexToColor(blendHexWithWhite(bg_hex, ratio), Blitbuffer.COLOR_WHITE),
        hexToColor(fg_hex, Blitbuffer.COLOR_BLACK)
end

-- No decorative filler in compact mode: it keeps the popup calm and uncluttered.
local function compactAccent(settings)
    return nil
end

local function isStatisticField(field)
    return field == "stat_time"
        or field == "stat_pages"
        or field == "stat_days"
        or field == "reading_pace"
        or field == "stat_highlights"
        or field == "stat_notes"
        or field == "stat_last_open"
end

-- Avoid opening KOReader's Statistics database unless at least one
-- statistics field is actually visible in the current showcase.
local function hasVisibleStatistics(settings)
    for _, field in ipairs(FIELD_KEYS) do
        if (isStatisticField(field) or field == "finished_date") and isVisible(settings, field) then
            return true
        end
    end
    return false
end

local function isReadingField(field)
    return field == "pages"
        or field == "progress"
        or field == "status"
        or field == "status_badge"
        or field == "finished_date"
end

local function prettyFieldText(field, value, settings)
    -- When labels are enabled, every field must show its full label.
    -- This includes the compact Reading and Statistics fields.
    if settings.show_labels and field ~= "footer" then
        return FIELD_LABELS[field] .. ": " .. value
    end

    if field == "author" then
        return _("By ") .. value
    elseif field == "rating" then
        return value
    elseif field == "title" then
        return value
    elseif field == "pages" then
        return value .. _(" pages")
    elseif field == "progress" or field == "status" or field == "status_badge" then
        return value
    elseif field == "finished_date" then
        return _("Finished on ") .. value
    elseif field == "stat_time" then
        return value .. _(" reading")
    elseif field == "stat_pages" then
        return value .. _(" pages read")
    elseif field == "stat_days" then
        return value .. _(" reading days")
    elseif field == "reading_pace" then
        return value
    elseif field == "stat_highlights" then
        return value .. _(" highlights")
    elseif field == "stat_notes" then
        return value .. _(" notes")
    elseif field == "stat_last_open" then
        return _("Last opened: ") .. value
    end

    return value
end
local function joinCompact(items)
    if #items == 0 then
        return nil
    end

    return table.concat(items, " • ")
end

local function buildFinishedBookCaption(settings, values)
    -- A focused completion card. This intentionally does not use the generic
    -- field grouping because finished books benefit from a short achievement
    -- summary instead of repeated status labels and raw statistics.
    local blocks = {}

    local function add(text)
        if text and text ~= "" then
            table.insert(blocks, text)
        end
    end

    local identity = {}
    if values.title then
        table.insert(identity, values.title)
    end
    if values.author then
        table.insert(identity, _("By ") .. values.author)
    end
    if settings.show_completion_badge and values.completion_badge then
        table.insert(identity, values.completion_badge)
    end
    if values.rating then
        table.insert(identity, values.rating)
    end
    add(table.concat(identity, "\n"))

    local completion = {}
    if values.finished_date then
        table.insert(completion, _("Finished on ") .. values.finished_date)
    elseif values.status == _("Finished reading") then
        table.insert(completion, _("Finished reading"))
    end
    if values.pages then
        table.insert(completion, values.pages .. _(" pages"))
    end
    add(joinCompact(completion))

    local statistics = {}
    if values.stat_time then
        table.insert(statistics, values.stat_time .. _(" reading"))
    end
    if values.stat_days then
        table.insert(statistics, values.stat_days .. _(" reading days"))
    end
    if values.stat_highlights then
        table.insert(statistics, values.stat_highlights .. _(" highlights"))
    end
    if values.stat_notes then
        table.insert(statistics, values.stat_notes .. _(" notes"))
    end
    add(joinCompact(statistics))

    if values.description then
        add(_("ABOUT") .. "\n" .. values.description)
    end

    local favourite_quote = styledFavouriteQuote(values.favourite_quote)
    if favourite_quote then
        add(_("FAVOURITE QUOTE") .. "\n" .. favourite_quote)
    end

    local review = styledReview(settings, values.review)
    if review then
        add(_("MY REVIEW") .. "\n" .. review)
    end

    -- The default hashtag is useful in normal cards but makes a finished-book
    -- card look less like a clean summary. Preserve a user-entered footer.
    if values.footer and values.footer ~= "#BookShowcase" then
        add(values.footer)
    end

    return table.concat(blocks, "\n\n")
end

local function buildPrettyCaption(settings, values)
    if settings.template == "finished" then
        return buildFinishedBookCaption(settings, values)
    end
    local lead = {}
    local reading = {}
    local statistics = {}
    local about = {}
    local other = {}
    local review = nil
    local footer = nil

    for _, field in ipairs(settings.field_order) do
        local value = values[field]
        if isVisible(settings, field) and value and value ~= "" then
            local text = prettyFieldText(field, value, settings)
            if field == "title" or field == "author" or field == "rating" then
                table.insert(lead, text)
            elseif isReadingField(field) then
                table.insert(reading, { field = field, text = text, value = value })
            elseif isStatisticField(field) then
                table.insert(statistics, { field = field, text = text, value = value })
            elseif field == "description" then
                table.insert(about, { field = field, text = text, value = value })
            elseif field == "review" then
                review = value
            elseif field == "footer" then
                footer = text
            else
                table.insert(other, { field = field, text = text, value = value })
            end
        end
    end

    local blocks = {}
    local function addBlock(text)
        if text and text ~= "" then
            table.insert(blocks, text)
        end
    end

    -- Keep author and rating visually close to the cover; do not add a heavy rule here.
    if settings.show_completion_badge and values.completion_badge then
        table.insert(lead, 1, values.completion_badge)
    end
    if #lead > 0 then
        addBlock(table.concat(lead, "\n"))
    end

    if #reading > 0 then
        local lines = {}
        local header = sectionHeader(settings, "READING")
        if header then table.insert(lines, header) end

        if settings.show_labels then
            for _, item in ipairs(reading) do
                table.insert(lines, FIELD_LABELS[item.field] .. ": " .. item.value)
            end
        else
            -- Keep the reading badge on its own line. It is a visual status
            -- marker, not part of the page/date summary.
            local compact = {}
            for _, item in ipairs(reading) do
                if item.field == "status_badge" then
                    table.insert(lines, item.text)
                else
                    table.insert(compact, item.text)
                end
            end
            local summary = joinCompact(compact)
            if summary then
                table.insert(lines, summary)
            end
        end
        addBlock(table.concat(lines, "\n"))
    end

    if #statistics > 0 then
        local lines = {}
        local header = sectionHeader(settings, "READING STATISTICS")
        if header then table.insert(lines, header) end

        if settings.show_labels then
            for _, item in ipairs(statistics) do
                table.insert(lines, FIELD_LABELS[item.field] .. ": " .. item.value)
            end
        else
            local compact = {}
            local already_added = {}
            local has_pace = false

            for _, item in ipairs(statistics) do
                if item.field == "reading_pace" then
                    has_pace = true
                end
                already_added[item.field] = true
            end

            -- Reading pace is clearer together with its source values. When
            -- pace is enabled, add pages read and reading days when available,
            -- even if they were not separately selected as visible fields.
            if has_pace then
                if values.stat_pages and not already_added.stat_pages then
                    table.insert(compact, prettyFieldText("stat_pages", values.stat_pages, settings))
                    already_added.stat_pages = true
                end
                if values.stat_days and not already_added.stat_days then
                    table.insert(compact, prettyFieldText("stat_days", values.stat_days, settings))
                    already_added.stat_days = true
                end
            end

            for _, item in ipairs(statistics) do
                table.insert(compact, item.text)
            end

            local summary = joinCompact(compact)
            if summary then
                table.insert(lines, summary)
            end
        end
        addBlock(table.concat(lines, "\n"))
    end

    if #other > 0 then
        local lines = {}
        for _, item in ipairs(other) do
            if settings.show_labels then
                table.insert(lines, FIELD_LABELS[item.field] .. ": " .. item.value)
            else
                table.insert(lines, item.text)
            end
        end
        addBlock(table.concat(lines, "\n"))
    end

    if #about > 0 then
        local lines = {}
        local header = sectionHeader(settings, "ABOUT")
        if header then table.insert(lines, header) end
        for _, item in ipairs(about) do
            if settings.show_labels then
                table.insert(lines, FIELD_LABELS[item.field] .. ":\n" .. item.value)
            else
                table.insert(lines, item.text)
            end
        end
        addBlock(table.concat(lines, "\n"))
    end

    local review_text = styledReview(settings, review)
    if review_text then
        local lines = {}
        local header = sectionHeader(settings, "MY REVIEW")
        if header then table.insert(lines, header) end
        if settings.show_labels then
            table.insert(lines, FIELD_LABELS.review .. ":\n" .. review_text)
        else
            table.insert(lines, review_text)
        end
        if footer and settings.footer_position == "below_review" then
            table.insert(lines, footer)
            footer = nil
        end
        addBlock(table.concat(lines, "\n"))
    end

    if footer then
        if settings.footer_style == "framed" then
            addBlock("┄┄┄┄┄┄┄┄\n" .. footer .. "\n┄┄┄┄┄┄┄┄")
        elseif settings.footer_style == "minimal" then
            addBlock("· " .. footer)
        elseif settings.show_footer_divider and not settings.social_card_mode then
            addBlock(footerDivider(settings) .. "\n" .. footer)
        else
            addBlock(footer)
        end
    end

    return table.concat(blocks, sectionGap(settings.card_density))
end

function BookShowcase:getBookStatistics(file, include_days)
    if lfs.attributes(STATS_DB, "mode") ~= "file" then
        return nil
    end

    local ok, result = pcall(function()
        local db = SQ3.open(STATS_DB)

        if not db then
            return nil
        end

        local md5 = util.partialMD5(file)

        if not md5 then
            db:close()
            return nil
        end

        local stmt = db:prepare([[
            SELECT
                id,
                notes,
                last_open,
                highlights,
                pages,
                total_read_time,
                total_read_pages
            FROM book
            WHERE md5 = ?
            LIMIT 1;
        ]])

        local row = stmt:reset():bind(md5):step()
        stmt:close()

        if not row then
            db:close()
            return nil
        end

        local id_book = tonumber(row[1])
        local stat_days = nil

        -- The daily-history query is comparatively expensive. Run it only
        -- when the Reading days field is enabled.
        if include_days and id_book then
            local days_stmt = db:prepare([[
                SELECT COUNT(*)
                FROM (
                    SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')
                    FROM page_stat
                    WHERE id_book = ?
                    GROUP BY strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')
                );
            ]])

            local days_row = days_stmt:reset():bind(id_book):step()
            days_stmt:close()

            if days_row then
                stat_days = tonumber(days_row[1])
            end
        end

        db:close()

        return {
            notes = tonumber(row[2]) or 0,
            last_open = tonumber(row[3]) or 0,
            highlights = tonumber(row[4]) or 0,
            pages = tonumber(row[5]) or 0,
            total_read_time = tonumber(row[6]) or 0,
            total_read_pages = tonumber(row[7]) or 0,
            days = stat_days or 0,
        }
    end)

    if not ok then
        return nil
    end

    return result
end

function BookShowcase:closeLongPressDialog()
    local dialog = UIManager:getTopmostVisibleWidget()

    if dialog then
        UIManager:close(dialog)
    end
end

function BookShowcase:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

-- Build a template without changing the user's global appearance choices.
-- Per-book templates use this to change the information layout only.
local function copySettingsTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function buildTemplateSettings(name, appearance_source)
    local settings = defaultSettings()
    settings.template = name

    if name == "classic" then
        settings.show_author = true
        settings.show_rating = true
        settings.show_review = true
        settings.show_footer = true
        settings.show_progress = true
        settings.show_status = true
        settings.show_status_badge = true
        settings.review_length = "medium"
        settings.review_style = "quote"

    elseif name == "stats" then
        settings.show_author = true
        settings.show_rating = true
        settings.show_review = false
        settings.show_footer = true
        settings.show_progress = true
        settings.show_status = true
        settings.show_status_badge = true
        settings.show_finished_date = true
        settings.show_stat_time = true
        settings.show_stat_pages = true
        settings.show_stat_days = true
        settings.show_reading_pace = true
        settings.show_stat_highlights = true
        settings.show_stat_notes = true
        settings.show_stat_last_open = true
        settings.show_section_headers = true

    elseif name == "review" then
        settings.show_author = true
        settings.show_rating = true
        settings.show_review = true
        settings.show_footer = true
        settings.show_progress = false
        settings.show_status = false
        settings.show_status_badge = false
        settings.show_finished_date = false
        settings.show_stat_time = false
        settings.show_stat_pages = false
        settings.show_stat_days = false
        settings.show_stat_highlights = false
        settings.show_stat_notes = false
        settings.show_stat_last_open = false
        settings.review_length = "full"
        settings.review_style = "framed"
        settings.card_density = "normal"

    elseif name == "full" then
        settings.show_title = true
        settings.show_author = true
        settings.show_series = true
        settings.show_series_index = true
        settings.show_language = true
        settings.show_keywords = true
        settings.show_description = true
        settings.show_pages = true
        settings.show_progress = true
        settings.show_status = true
        settings.show_status_badge = true
        settings.show_finished_date = true
        settings.show_stat_time = true
        settings.show_stat_pages = true
        settings.show_stat_days = true
        settings.show_reading_pace = true
        settings.show_stat_highlights = true
        settings.show_stat_notes = true
        settings.show_stat_last_open = true
        settings.show_rating = true
        settings.show_review = true
        settings.show_footer = true
        settings.show_labels = true
        settings.description_length = "medium"
        settings.review_length = "medium"
        settings.review_style = "quote"

    elseif name == "finished" then
        -- Completion card: concise, shareable, and deliberately avoids
        -- ambiguous statistics such as partial "pages read" data.
        settings.show_title = true
        settings.show_author = true
        settings.show_description = true
        settings.show_pages = true
        settings.show_series = false
        settings.show_series_index = false
        settings.show_rating = true
        settings.show_review = true
        settings.show_footer = true
        settings.show_progress = false
        settings.show_status = false
        settings.show_status_badge = false
        settings.show_finished_date = true
        settings.show_stat_time = true
        settings.show_stat_pages = false
        settings.show_stat_days = true
        settings.show_reading_pace = false
        settings.show_stat_highlights = true
        settings.show_stat_notes = true
        settings.show_stat_last_open = false
        settings.show_labels = false
        settings.description_length = "short"
        settings.review_length = "medium"
        settings.review_style = "quote"
        settings.card_density = "compact"
        settings.show_section_headers = false
        settings.auto_finished_footer = false

    elseif name == "social" then
        settings.show_author = true
        settings.show_rating = true
        settings.show_review = true
        settings.show_footer = true
        settings.show_progress = false
        settings.show_status = false
        settings.show_status_badge = false
        settings.show_finished_date = false
        settings.show_stat_time = false
        settings.show_stat_pages = false
        settings.show_stat_days = false
        settings.show_stat_highlights = false
        settings.show_stat_notes = false
        settings.show_stat_last_open = false
        settings.show_labels = false
        settings.social_card_mode = true
        settings.social_review_short = true
        settings.review_length = "short"
        settings.review_style = "quote"
        settings.card_density = "compact"
        settings.show_section_headers = false
    end

    if appearance_source then
        -- Keep the user's general visual setup consistent across every card.
        for _, key in ipairs({
            "show_title_bar", "footer_text", "custom_colors_enabled",
            "custom_bg_color", "custom_fg_color", "accent_style",
            "text_alignment", "popup_size", "background_strength",
            "popup_border", "rating_style", "section_icons", "footer_style",
            "show_footer_divider", "footer_position", "auto_finished_footer",
            "hide_unknown_author",
        }) do
            settings[key] = appearance_source[key]
        end
        settings.saved_presets = appearance_source.saved_presets or {}
    end

    ensureOrder(settings)
    return settings
end

function BookShowcase:showTemplateMenu()
    local dialog

    local function applyTemplate(name)
        local settings = buildTemplateSettings(name)
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:showPresetsMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Showcase template"),
        buttons = {
            {{ text = _("Classic Card"), callback = function() applyTemplate("classic") end }},
            {{ text = _("Stats Card"), callback = function() applyTemplate("stats") end }},
            {{ text = _("Review Focus"), callback = function() applyTemplate("review") end }},
            {{ text = _("Full Metadata"), callback = function() applyTemplate("full") end }},
            {{ text = _("Minimal Social"), callback = function() applyTemplate("social") end }},
            {{ text = _("Finished Book"), callback = function() applyTemplate("finished") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showPresetsMenu() end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showVisibilityMenu()
    local settings = getSettings()
    local dialog

    local function toggle(key)
        settings[key] = not settings[key]
        saveSettings(settings)

        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showVisibilityMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Show / hide metadata"),
        buttons = {
            {
                {
                    text = _("Title bar: ") .. onOff(settings.show_title_bar),
                    callback = function() toggle("show_title_bar") end,
                },
            },
            {
                {
                    text = _("Title in metadata: ") .. onOff(settings.show_title),
                    callback = function() toggle("show_title") end,
                },
            },
            {
                {
                    text = _("Author: ") .. onOff(settings.show_author),
                    callback = function() toggle("show_author") end,
                },
            },
            {
                {
                    text = _("Series: ") .. onOff(settings.show_series),
                    callback = function() toggle("show_series") end,
                },
            },
            {
                {
                    text = _("Series number: ") .. onOff(settings.show_series_index),
                    callback = function() toggle("show_series_index") end,
                },
            },
            {
                {
                    text = _("Language: ") .. onOff(settings.show_language),
                    callback = function() toggle("show_language") end,
                },
            },
            {
                {
                    text = _("Tags: ") .. onOff(settings.show_keywords),
                    callback = function() toggle("show_keywords") end,
                },
            },
            {
                {
                    text = _("Description: ") .. onOff(settings.show_description),
                    callback = function() toggle("show_description") end,
                },
            },
            {
                {
                    text = _("Pages: ") .. onOff(settings.show_pages),
                    callback = function() toggle("show_pages") end,
                },
            },
            {
                {
                    text = _("Reading progress: ") .. onOff(settings.show_progress),
                    callback = function() toggle("show_progress") end,
                },
            },
            {
                {
                    text = _("Reading status: ") .. onOff(settings.show_status),
                    callback = function() toggle("show_status") end,
                },
            },
            {
                {
                    text = _("Status badge: ") .. onOff(settings.show_status_badge),
                    callback = function() toggle("show_status_badge") end,
                },
            },
            {
                {
                    text = _("Finished date: ") .. onOff(settings.show_finished_date),
                    callback = function() toggle("show_finished_date") end,
                },
            },
            {
                {
                    text = _("Reading time: ") .. onOff(settings.show_stat_time),
                    callback = function() toggle("show_stat_time") end,
                },
            },
            {
                {
                    text = _("Pages read: ") .. onOff(settings.show_stat_pages),
                    callback = function() toggle("show_stat_pages") end,
                },
            },
            {
                {
                    text = _("Reading days: ") .. onOff(settings.show_stat_days),
                    callback = function() toggle("show_stat_days") end,
                },
            },
            {
                {
                    text = _("Reading pace: ") .. onOff(settings.show_reading_pace),
                    callback = function() toggle("show_reading_pace") end,
                },
            },
            {
                {
                    text = _("Highlights: ") .. onOff(settings.show_stat_highlights),
                    callback = function() toggle("show_stat_highlights") end,
                },
            },
            {
                {
                    text = _("Notes: ") .. onOff(settings.show_stat_notes),
                    callback = function() toggle("show_stat_notes") end,
                },
            },
            {
                {
                    text = _("Last opened: ") .. onOff(settings.show_stat_last_open),
                    callback = function() toggle("show_stat_last_open") end,
                },
            },
            {
                {
                    text = _("Rating: ") .. onOff(settings.show_rating),
                    callback = function() toggle("show_rating") end,
                },
            },
            {
                {
                    text = _("Review: ") .. onOff(settings.show_review),
                    callback = function() toggle("show_review") end,
                },
            },
            {
                {
                    text = _("Footer: ") .. onOff(settings.show_footer),
                    callback = function() toggle("show_footer") end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)

                        UIManager:nextTick(function()
                            self:showContentMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showOrderMenu()
    local settings = getSettings()
    local dialog
    local active_fields = getVisibleFields(settings)

    local function shift(field, direction)
        moveVisibleField(settings, field, direction)
        saveSettings(settings)

        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showOrderMenu()
        end)
    end

    local buttons = {
        {
            {
                text = _("Visible order: ") .. visibleOrderText(settings),
                enabled = false,
            },
        },
    }

    for _, field in ipairs(active_fields) do
        table.insert(buttons, {
            {
                text = FIELD_LABELS[field] .. " ↑",
                callback = function()
                    shift(field, -1)
                end,
            },
            {
                text = FIELD_LABELS[field] .. " ↓",
                callback = function()
                    shift(field, 1)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Reset all order"),
            callback = function()
                settings.field_order = defaultOrder()
                saveSettings(settings)

                UIManager:close(dialog)

                UIManager:nextTick(function()
                    self:showOrderMenu()
                end)
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("← Back"),
            callback = function()
                UIManager:close(dialog)

                UIManager:nextTick(function()
                    self:showContentMenu()
                end)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Arrange visible metadata"),
        buttons = buttons,
    }

    UIManager:show(dialog)
end

function BookShowcase:showLengthMenu(kind)
    local settings = getSettings()
    local dialog

    local key = kind == "description" and "description_length" or "review_length"
    local title = kind == "description" and _("Description length") or _("Review length")

    local function setLength(mode)
        settings[key] = mode
        saveSettings(settings)

        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showFormattingMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = title,
        buttons = {
            {
                {
                    text = _("Current: ") .. lengthLabel(settings[key]),
                    enabled = false,
                },
            },
            {
                {
                    text = _("Short"),
                    callback = function() setLength("short") end,
                },
            },
            {
                {
                    text = _("Medium"),
                    callback = function() setLength("medium") end,
                },
            },
            {
                {
                    text = _("Full"),
                    callback = function() setLength("full") end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)

                        UIManager:nextTick(function()
                            self:showFormattingMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showSpacingMenu()
    local settings = getSettings()
    local dialog

    local function setSpacing(mode)
        settings.spacing = mode
        saveSettings(settings)

        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showFormattingMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Metadata spacing"),
        buttons = {
            {
                {
                    text = _("Current: ") .. spacingLabel(settings.spacing),
                    enabled = false,
                },
            },
            {
                {
                    text = _("Compact"),
                    callback = function() setSpacing("compact") end,
                },
            },
            {
                {
                    text = _("Normal"),
                    callback = function() setSpacing("normal") end,
                },
            },
            {
                {
                    text = _("Spacious"),
                    callback = function() setSpacing("spacious") end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)

                        UIManager:nextTick(function()
                            self:showFormattingMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showFooterTextDialog()
    local settings = getSettings()
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Default footer text"),
        input = settings.footer_text or "#BookShowcase",
        buttons = {
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(input_dialog)

                        UIManager:nextTick(function()
                            self:showFormattingMenu()
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = input_dialog:getInputText()

                        if value and value ~= "" then
                            settings.footer_text = value
                            saveSettings(settings)
                        end

                        UIManager:close(input_dialog)

                        UIManager:nextTick(function()
                            self:showFormattingMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookShowcase:showPerBookFooterDialog(file, on_done)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Showcase footer for this book"),
        input = summary.bookshowcase_footer or "",
        buttons = {
            {
                {
                    text = _("Clear"),
                    callback = function()
                        summary.bookshowcase_footer = nil
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = input_dialog:getInputText()

                        if value and value ~= "" then
                            summary.bookshowcase_footer = value
                        else
                            summary.bookshowcase_footer = nil
                        end

                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Returns the effective profile for this book.  The action menu uses the
-- same settings as the visible card, so it never offers unrelated edits.
function BookShowcase:getEffectiveShowcaseSettings(file)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local global_settings = getSettings()
    local book_template = cleanText(summary.bookshowcase_template)
    local settings = book_template and buildTemplateSettings(book_template, global_settings) or global_settings
    return settings, summary
end

local SHOWCASE_OVERRIDE_FIELDS = {
    title = "title",
    author = "authors",
    series = "series",
    series_index = "series_index",
    language = "language",
    keywords = "keywords",
    description = "description",
    pages = "pages",
}

local AUTOMATIC_FIELDS = {
    progress = true,
    status_badge = true,
    stat_time = true,
    stat_pages = true,
    stat_days = true,
    reading_pace = true,
    stat_highlights = true,
    stat_notes = true,
    stat_last_open = true,
}

local function isFinishedProfile(settings)
    return settings and settings.template == "finished"
end

local function isFieldDisplayedInProfile(settings, field)
    -- Finished Book has a deliberately curated layout instead of using the
    -- generic visible-field order.  Treat all of its shown, user-editable
    -- fields as displayed in the action list.
    if isFinishedProfile(settings) then
        local finished_fields = {
            title = true,
            author = true,
            description = true,
            pages = true,
            finished_date = true,
            rating = true,
            review = true,
            footer = true,
            favourite_quote = true,
        }
        return finished_fields[field] or false
    end

    if field == "favourite_quote" then
        -- Favourite Quote is currently rendered only by Finished Book.
        return false
    end

    return isVisible(settings, field)
end

function BookShowcase:editBookShowcaseMetadata(file, field, on_done)
    local prop_key = SHOWCASE_OVERRIDE_FIELDS[field]
    if not prop_key then
        return
    end

    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local saved_props = doc_settings:readSetting("doc_props") or {}
    summary.bookshowcase_overrides = summary.bookshowcase_overrides or {}
    local overrides = summary.bookshowcase_overrides
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Edit ") .. (FIELD_LABELS[field] or field),
        -- Start from the current stored metadata when no Showcase-only
        -- override exists, so editing Author/Description does not require
        -- retyping it from scratch.
        input = overrides[prop_key] or saved_props[prop_key] or "",
        buttons = {
            {
                {
                    text = _("Clear override"),
                    callback = function()
                        overrides[prop_key] = nil
                        if next(overrides) == nil then
                            summary.bookshowcase_overrides = nil
                        end
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then UIManager:nextTick(on_done) end
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = cleanText(input_dialog:getInputText())
                        overrides[prop_key] = value
                        if next(overrides) == nil then
                            summary.bookshowcase_overrides = nil
                        end
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then UIManager:nextTick(on_done) end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(input_dialog) end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookShowcase:editBookFinishedDate(file, on_done)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Finished date"),
        input = summary.bookshowcase_finished_date or completionDateText(summary) or "",
        buttons = {
            {
                {
                    text = _("Clear override"),
                    callback = function()
                        summary.bookshowcase_finished_date = nil
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then UIManager:nextTick(on_done) end
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        summary.bookshowcase_finished_date = cleanText(input_dialog:getInputText())
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then UIManager:nextTick(on_done) end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(input_dialog) end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookShowcase:showAutomaticFieldInfo(field)
    local text = (FIELD_LABELS[field] or field) .. "\n\n" .. _("This value is read automatically from KOReader's reading progress, statistics or highlights. It cannot be edited in Book Showcase.")
    self:showInfo(text)
end

function BookShowcase:showDisplayedFieldsMenu(viewer, file, book_props)
    local settings = self:getEffectiveShowcaseSettings(file)
    local dialog
    local buttons = {}

    local function refresh()
        self:refreshShowcase(viewer, file, book_props)
    end

    local function editMetadata(field)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:editBookShowcaseMetadata(file, field, refresh)
        end)
    end

    local function addButton(text, callback)
        table.insert(buttons, { { text = text, callback = callback } })
    end

    -- Follow the configured card order. Each displayed field is represented.
    local status_action_added = false
    for _, field in ipairs(settings.field_order or FIELD_KEYS) do
        if isFieldDisplayedInProfile(settings, field) then
            if SHOWCASE_OVERRIDE_FIELDS[field] then
                addButton(_("Edit ") .. FIELD_LABELS[field], function() editMetadata(field) end)
            elseif field == "rating" then
                addButton(_("Edit rating"), function()
                    UIManager:close(dialog)
                    UIManager:nextTick(function() self:editBookRating(file, refresh) end)
                end)
            elseif field == "review" then
                addButton(_("Edit review"), function()
                    UIManager:close(dialog)
                    UIManager:nextTick(function() self:editBookReview(file, refresh) end)
                end)
            elseif field == "footer" then
                addButton(_("Edit footer"), function()
                    UIManager:close(dialog)
                    UIManager:nextTick(function() self:showPerBookFooterDialog(file, refresh) end)
                end)
            elseif field == "status" or field == "status_badge" then
                if not status_action_added then
                    status_action_added = true
                    addButton(_("Change reading status"), function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function() self:editBookStatus(file, refresh) end)
                    end)
                end
            elseif field == "finished_date" then
                addButton(_("Edit finished date"), function()
                    UIManager:close(dialog)
                    UIManager:nextTick(function() self:editBookFinishedDate(file, refresh) end)
                end)
            elseif AUTOMATIC_FIELDS[field] then
                addButton((FIELD_LABELS[field] or field) .. _(" (automatic)"), function()
                    self:showAutomaticFieldInfo(field)
                end)
            end
        end
    end

    if isFieldDisplayedInProfile(settings, "favourite_quote") then
        addButton(_("Edit favourite quote"), function()
            UIManager:close(dialog)
            UIManager:nextTick(function() self:editBookFavouriteQuote(file, refresh) end)
        end)
    end

    if #buttons == 0 then
        addButton(_("No editable fields are displayed"), function()
            self:showInfo(_("Turn on fields in Book Showcase settings, then reopen the showcase."))
        end)
    end

    table.insert(buttons, {
        {
            text = _("← Back"),
            callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    self:showShowcaseActions(viewer, file, book_props)
                end)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Edit displayed fields"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function BookShowcase:refreshShowcase(viewer, file, book_props)
    -- Keep the current display mode after an edit, including the clean
    -- full-screen presentation card used for screenshots or sharing.
    local presentation_mode = viewer and viewer.showcase_presentation_mode or false

    if viewer then
        UIManager:close(viewer)
    end

    UIManager:nextTick(function()
        self:showBookShowcase(file, book_props, presentation_mode)
    end)
end

function BookShowcase:editBookRating(file, on_done)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local dialog

    local function buttonFor(rating)
        local label = rating == 0 and _("Clear rating") or string.rep("★", rating)
        return {
            text = label,
            callback = function()
                summary.rating = rating == 0 and nil or rating
                doc_settings:saveSetting("summary", summary)
                doc_settings:flush()
                UIManager:close(dialog)
                if on_done then
                    UIManager:nextTick(on_done)
                end
            end,
        }
    end

    dialog = ButtonDialog:new{
        title = _("Rating"),
        buttons = {
            { buttonFor(1), buttonFor(2) },
            { buttonFor(3), buttonFor(4) },
            { buttonFor(5), buttonFor(0) },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function BookShowcase:editBookReview(file, on_done)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Review for this book"),
        input = summary.note or "",
        buttons = {
            {
                {
                    text = _("Clear"),
                    callback = function()
                        summary.note = nil
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = input_dialog:getInputText()
                        summary.note = value and value ~= "" and value or nil
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookShowcase:editBookFavouriteQuote(file, on_done)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Favourite quote for this book"),
        input = summary.bookshowcase_favourite_quote or "",
        buttons = {
            {
                {
                    text = _("Clear"),
                    callback = function()
                        summary.bookshowcase_favourite_quote = nil
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = cleanText(input_dialog:getInputText())
                        summary.bookshowcase_favourite_quote = value
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(input_dialog)
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookShowcase:editBookStatus(file, on_done)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local dialog

    local function saveStatus(value)
        summary.status = value
        doc_settings:saveSetting("summary", summary)
        doc_settings:flush()
        UIManager:close(dialog)
        if on_done then
            UIManager:nextTick(on_done)
        end
    end

    dialog = ButtonDialog:new{
        title = _("Reading status"),
        buttons = {
            {
                {
                    text = _("Reading"),
                    callback = function() saveStatus("reading") end,
                },
                {
                    text = _("Finished"),
                    callback = function() saveStatus("complete") end,
                },
            },
            {
                {
                    text = _("On hold"),
                    callback = function() saveStatus("abandoned") end,
                },
                {
                    text = _("Clear status"),
                    callback = function() saveStatus(nil) end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function BookShowcase:showBookProfileMenu(viewer, file, book_props)
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    local current = summary.bookshowcase_template
    local dialog

    local function choose(template)
        summary.bookshowcase_template = template
        doc_settings:saveSetting("summary", summary)
        doc_settings:flush()
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:refreshShowcase(viewer, file, book_props)
        end)
    end

    dialog = ButtonDialog:new{
        title = current and (_("Card profile: ") .. current) or _("Card profile: Global setup"),
        buttons = {
            {
                {
                    text = _("Use global setup"),
                    callback = function()
                        summary.bookshowcase_template = nil
                        doc_settings:saveSetting("summary", summary)
                        doc_settings:flush()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:refreshShowcase(viewer, file, book_props)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Classic Card"),
                    callback = function() choose("classic") end,
                },
                {
                    text = _("Stats Card"),
                    callback = function() choose("stats") end,
                },
            },
            {
                {
                    text = _("Review Focus"),
                    callback = function() choose("review") end,
                },
                {
                    text = _("Full Metadata"),
                    callback = function() choose("full") end,
                },
            },
            {
                {
                    text = _("Minimal Social"),
                    callback = function() choose("social") end,
                },
                {
                    text = _("Finished Book"),
                    callback = function() choose("finished") end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showFullBookDescription(file, book_props)
    local doc_settings = DocSettings:open(file)
    local saved_props = doc_settings:readSetting("doc_props") or {}
    local summary = doc_settings:readSetting("summary") or {}
    local overrides = summary.bookshowcase_overrides or {}
    local custom_props = {}
    local custom_metadata_file = DocSettings:findCustomMetadataFile(file)
    if custom_metadata_file then
        local custom_settings = DocSettings.openSettingsFile(custom_metadata_file)
        custom_props = custom_settings:readSetting("custom_props") or {}
    end
    local description = cleanText(overrides.description or custom_props.description
        or (book_props or {}).description or saved_props.description)
    if description then
        description = util.htmlToPlainTextIfHtml(description)
    end
    self:showInfo(description or _("No description is available for this book."))
end

function BookShowcase:showShowcaseActions(viewer, file, book_props)
    local dialog
    local function refresh()
        self:refreshShowcase(viewer, file, book_props)
    end

    local function openEditor(editor)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            editor(file, refresh)
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Showcase actions"),
        buttons = {
            {
                {
                    text = _("Edit rating"),
                    callback = function()
                        openEditor(function(book_file, done)
                            self:editBookRating(book_file, done)
                        end)
                    end,
                },
                {
                    text = _("Edit review"),
                    callback = function()
                        openEditor(function(book_file, done)
                            self:editBookReview(book_file, done)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Edit footer"),
                    callback = function()
                        openEditor(function(book_file, done)
                            self:showPerBookFooterDialog(book_file, done)
                        end)
                    end,
                },
                {
                    text = _("Change status"),
                    callback = function()
                        openEditor(function(book_file, done)
                            self:editBookStatus(book_file, done)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Read full description"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showFullBookDescription(file, book_props)
                        end)
                    end,
                },
                {
                    text = _("Edit favourite quote"),
                    callback = function()
                        openEditor(function(book_file, done)
                            self:editBookFavouriteQuote(book_file, done)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Change card profile"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showBookProfileMenu(viewer, file, book_props)
                        end)
                    end,
                },
                {
                    text = _("Global showcase settings"),
                    callback = function()
                        UIManager:close(dialog)
                        if viewer then
                            UIManager:close(viewer)
                        end
                        UIManager:nextTick(function()
                            self:showSettings()
                        end)
                    end,
                },
            },
            {
                {
                    text = viewer and viewer.showcase_presentation_mode
                        and _("Exit presentation mode") or _("Presentation mode"),
                    callback = function()
                        local next_mode = not (viewer and viewer.showcase_presentation_mode)
                        UIManager:close(dialog)
                        if viewer then
                            UIManager:close(viewer)
                        end
                        UIManager:nextTick(function()
                            self:showBookShowcase(file, book_props, next_mode)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showCoverSizeMenu()
    local settings = getSettings()
    local dialog

    local function setCoverSize(size)
        settings.cover_size = size
        saveSettings(settings)
        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Cover size"),
        buttons = {
            {
                {
                    text = _("Small"),
                    callback = function() setCoverSize("small") end,
                },
            },
            {
                {
                    text = _("Medium"),
                    callback = function() setCoverSize("medium") end,
                },
            },
            {
                {
                    text = _("Large"),
                    callback = function() setCoverSize("large") end,
                },
            },
            {
                {
                    text = _("Very large"),
                    callback = function() setCoverSize("very_large") end,
                },
            },
            {
                {
                    text = _("Huge"),
                    callback = function() setCoverSize("huge") end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAppearanceMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showDensityMenu()
    local settings = getSettings()
    local dialog

    local function setDensity(density)
        settings.card_density = density
        saveSettings(settings)
        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Card density"),
        buttons = {
            {
                {
                    text = _("Compact"),
                    callback = function() setDensity("compact") end,
                },
            },
            {
                {
                    text = _("Normal"),
                    callback = function() setDensity("normal") end,
                },
            },
            {
                {
                    text = _("Spacious"),
                    callback = function() setDensity("spacious") end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAppearanceMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showAccentMenu()
    local settings = getSettings()
    local dialog

    local function setAccent(accent)
        settings.accent_style = accent
        saveSettings(settings)
        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Heading accent"),
        buttons = {
            {
                {
                    text = _("Line"),
                    callback = function() setAccent("line") end,
                },
            },
            {
                {
                    text = _("Star"),
                    callback = function() setAccent("star") end,
                },
            },
            {
                {
                    text = _("Dot"),
                    callback = function() setAccent("dot") end,
                },
            },
            {
                {
                    text = _("Dash"),
                    callback = function() setAccent("bold") end,
                },
            },
            {
                {
                    text = _("None"),
                    callback = function() setAccent("none") end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAppearanceMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showCardStyleMenu()
    local settings = getSettings()
    local dialog

    local function setStyle(style)
        settings.card_style = style
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Card style"),
        buttons = {
            {{ text = _("Modern"), callback = function() setStyle("modern") end }},
            {{ text = _("Elegant"), callback = function() setStyle("elegant") end }},
            {{ text = _("Minimal"), callback = function() setStyle("minimal") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    self:showAppearanceMenu()
                end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showTextAlignmentMenu()
    local settings = getSettings()
    local dialog

    local function setAlignment(alignment)
        settings.text_alignment = alignment
        saveSettings(settings)
        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Text alignment"),
        buttons = {
            {
                {
                    text = _("Left"),
                    callback = function() setAlignment("left") end,
                },
            },
            {
                {
                    text = _("Centre"),
                    callback = function() setAlignment("center") end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAppearanceMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end



function BookShowcase:showReviewStyleMenu()
    local settings = getSettings()
    local dialog

    local function setStyle(style)
        settings.review_style = style
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showFormattingMenu() end)
    end

    dialog = ButtonDialog:new{
        title = _("Review style"),
        buttons = {
            {{ text = _("Quote"), callback = function() setStyle("quote") end }},
            {{ text = _("Plain"), callback = function() setStyle("plain") end }},
            {{ text = _("Framed quote"), callback = function() setStyle("framed") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showFormattingMenu() end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showFooterPositionMenu()
    local settings = getSettings()
    local dialog

    local function setPosition(position)
        settings.footer_position = position
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showFormattingMenu() end)
    end

    dialog = ButtonDialog:new{
        title = _("Footer position"),
        buttons = {
            {{ text = _("Below review"), callback = function() setPosition("below_review") end }},
            {{ text = _("Bottom of card"), callback = function() setPosition("bottom") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showFormattingMenu() end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showCustomColorDialog(kind)
    local settings = getSettings()
    local input_dialog
    local key = kind == "background" and "custom_bg_color" or "custom_fg_color"
    local title = kind == "background" and _("Background colour") or _("Font colour")

    input_dialog = InputDialog:new{
        title = title .. _(" (HEX: #RRGGBB)"),
        input = settings[key] or (kind == "background" and "#FFFFFF" or "#000000"),
        buttons = {
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(input_dialog)
                        UIManager:nextTick(function()
                            self:showCustomColorsMenu()
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local color = normalizeHexColor(input_dialog:getInputText())

                        if not color then
                            self:showInfo(_("Enter a valid colour, for example #FFFFFF or 1A2B3C."))
                            return
                        end

                        settings[key] = color
                        settings.custom_colors_enabled = true
                        saveSettings(settings)
                        UIManager:close(input_dialog)

                        UIManager:nextTick(function()
                            self:showCustomColorsMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookShowcase:showCustomColorsMenu()
    local settings = getSettings()
    local dialog

    local function toggleCustom()
        settings.custom_colors_enabled = not settings.custom_colors_enabled
        saveSettings(settings)
        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showCustomColorsMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Custom colours"),
        buttons = {
            {
                {
                    text = _("Background theme: ") .. backgroundThemeLabel(settings.background_theme),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function() self:showBackgroundThemeMenu() end)
                    end,
                },
            },
            {
                {
                    text = _("Use custom colours: ") .. onOff(settings.custom_colors_enabled),
                    callback = toggleCustom,
                },
            },
            {
                {
                    text = _("Background: ") .. (settings.custom_bg_color or "#FFFFFF"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showCustomColorDialog("background")
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Font colour: ") .. (settings.custom_fg_color or "#000000"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showCustomColorDialog("font")
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Reset to default light colours"),
                    callback = function()
                        settings.custom_bg_color = "#FFFFFF"
                        settings.custom_fg_color = "#000000"
                        settings.custom_colors_enabled = false
                        saveSettings(settings)
                        UIManager:close(dialog)

                        UIManager:nextTick(function()
                            self:showCustomColorsMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAppearanceMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showPopupSizeMenu()
    local settings = getSettings()
    local dialog

    local function setPopupSize(size)
        settings.popup_size = size
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Showcase window size"),
        buttons = {
            {{ text = _("Small popup"), callback = function() setPopupSize("small") end }},
            {{ text = _("Medium popup"), callback = function() setPopupSize("medium") end }},
            {{ text = _("Large popup"), callback = function() setPopupSize("large") end }},
            {{ text = _("Near full screen"), callback = function() setPopupSize("near_full") end }},
            {{ text = _("Full screen"), callback = function() setPopupSize("fullscreen") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    self:showAppearanceMenu()
                end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showBackgroundStrengthMenu()
    local settings = getSettings()
    local dialog

    local function setStrength(strength)
        settings.background_strength = strength
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Background strength"),
        buttons = {
            {{ text = _("Soft"), callback = function() setStrength("soft") end }},
            {{ text = _("Normal"), callback = function() setStrength("normal") end }},
            {{ text = _("Solid"), callback = function() setStrength("solid") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    self:showAppearanceMenu()
                end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showPopupBorderMenu()
    local settings = getSettings()
    local dialog

    local function setBorder(border)
        settings.popup_border = border
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Popup border"),
        buttons = {
            {{ text = _("No border"), callback = function() setBorder("none") end }},
            {{ text = _("Thin"), callback = function() setBorder("thin") end }},
            {{ text = _("Medium"), callback = function() setBorder("medium") end }},
            {{ text = _("Thick"), callback = function() setBorder("thick") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    self:showAppearanceMenu()
                end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showRatingStyleMenu()
    local settings = getSettings()
    local dialog

    local function setStyle(style)
        settings.rating_style = style
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showAppearanceMenu() end)
    end

    dialog = ButtonDialog:new{
        title = _("Rating style"),
        buttons = {
            {{ text = _("Stars  ★★★★★"), callback = function() setStyle("stars") end }},
            {{ text = _("Hearts  ♥♥♥♥♥"), callback = function() setStyle("hearts") end }},
            {{ text = _("Dots  ●●●●●"), callback = function() setStyle("dots") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showAppearanceMenu() end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showFooterStyleMenu()
    local settings = getSettings()
    local dialog

    local function setStyle(style)
        settings.footer_style = style
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showFormattingMenu() end)
    end

    dialog = ButtonDialog:new{
        title = _("Footer style"),
        buttons = {
            {{ text = _("Simple"), callback = function() setStyle("simple") end }},
            {{ text = _("Framed"), callback = function() setStyle("framed") end }},
            {{ text = _("Minimal"), callback = function() setStyle("minimal") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showFormattingMenu() end)
            end }},
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showBackgroundThemeMenu()
    local settings = getSettings()
    local dialog
    local function setTheme(theme)
        settings.background_theme = theme
        -- Preset themes must visibly take effect immediately.
        -- Only the Custom colours choice should use the saved custom palette.
        settings.custom_colors_enabled = (theme == "custom")
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showAppearanceMenu() end)
    end
    dialog = ButtonDialog:new{
        title = _("Background theme"),
        buttons = {
            {{ text = _("Paper"), callback = function() setTheme("paper") end }},
            {{ text = _("Warm paper"), callback = function() setTheme("warm") end }},
            {{ text = _("Slate"), callback = function() setTheme("slate") end }},
            {{ text = _("Night"), callback = function() setTheme("night") end }},
            {{ text = _("Custom colours"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showCustomColorsMenu() end)
            end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showAppearanceMenu() end)
            end }},
        },
    }
    UIManager:show(dialog)
end

function BookShowcase:showCoverControlsMenu()
    local settings = getSettings()
    local dialog
    local function toggleZoom()
        settings.cover_zoom_locked = not settings.cover_zoom_locked
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showCoverControlsMenu() end)
    end
    dialog = ButtonDialog:new{
        title = _("Cover controls"),
        buttons = {
            {{ text = _("Cover size: ") .. coverSizeLabel(settings.cover_size), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showCoverSizeMenu() end)
            end }},
            {{ text = _("Touch zoom: ") .. coverZoomLabel(settings.cover_zoom_locked), callback = toggleZoom }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showAppearanceMenu() end)
            end }},
        },
    }
    UIManager:show(dialog)
end

function BookShowcase:showPresentationLayoutMenu()
    local settings = getSettings()
    local dialog
    local function setLayout(layout)
        settings.presentation_layout = layout
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showAppearanceMenu() end)
    end
    dialog = ButtonDialog:new{
        title = _("Screenshot layout"),
        buttons = {
            {{ text = _("Balanced"), callback = function() setLayout("balanced") end }},
            {{ text = _("Cover focus"), callback = function() setLayout("cover_focus") end }},
            {{ text = _("Details focus"), callback = function() setLayout("details_focus") end }},
            {{ text = _("← Back"), callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function() self:showAppearanceMenu() end)
            end }},
        },
    }
    UIManager:show(dialog)
end

function BookShowcase:showAppearanceMenu()
    local settings = getSettings()
    local dialog

    local function toggle(key)
        settings[key] = not settings[key]
        saveSettings(settings)
        UIManager:close(dialog)

        UIManager:nextTick(function()
            self:showAppearanceMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Showcase appearance"),
        buttons = {
            {
                {
                    text = _("Background theme: ") .. backgroundThemeLabel(settings.background_theme),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showBackgroundThemeMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Custom colours: ") .. onOff(settings.custom_colors_enabled),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showCustomColorsMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Background strength: ") .. backgroundStrengthLabel(settings.background_strength),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showBackgroundStrengthMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Popup border: ") .. popupBorderLabel(settings.popup_border),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showPopupBorderMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Window size: ") .. popupSizeLabel(settings.popup_size),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showPopupSizeMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Heading accent: ") .. accentLabel(settings.accent_style),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAccentMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Rating style: ") .. ratingStyleLabel(settings.rating_style),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showRatingStyleMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Completion badge: ") .. onOff(settings.show_completion_badge),
                    callback = function()
                        toggle("show_completion_badge")
                    end,
                },
            },
            {
                {
                    text = _("Section icons: ") .. onOff(settings.section_icons),
                    callback = function()
                        toggle("section_icons")
                    end,
                },
            },
            {
                {
                    text = _("Text alignment: ") .. alignmentLabel(settings.text_alignment),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showTextAlignmentMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cover controls"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function() self:showCoverControlsMenu() end)
                    end,
                },
            },
            {
                {
                    text = _("Screenshot layout: ") .. presentationLayoutLabel(settings.presentation_layout),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function() self:showPresentationLayoutMenu() end)
                    end,
                },
            },
            {
                {
                    text = _("Card density: ") .. densityLabel(settings.card_density),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showDensityMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Section headings: ") .. onOff(settings.show_section_headers),
                    callback = function()
                        toggle("show_section_headers")
                    end,
                },
            },
            {
                {
                    text = _("Footer divider: ") .. onOff(settings.show_footer_divider),
                    callback = function()
                        toggle("show_footer_divider")
                    end,
                },
            },
            {
                {
                    text = _("Minimal social card: ") .. onOff(settings.social_card_mode),
                    callback = function()
                        toggle("social_card_mode")
                    end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSettings()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showSavePresetDialog()
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Save showcase preset"),
        input = "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                        UIManager:nextTick(function()
                            self:showSavedPresetsMenu()
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local name = cleanText(input_dialog:getInputText())

                        if not name then
                            return
                        end

                        local settings = getSettings()
                        settings.saved_presets = settings.saved_presets or {}
                        settings.saved_presets[name] = makePresetFromSettings(settings)
                        saveSettings(settings)

                        UIManager:close(input_dialog)
                        UIManager:nextTick(function()
                            self:showSavedPresetsMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function BookShowcase:showSavedPresetActions(name)
    local settings = getSettings()
    local dialog

    dialog = ButtonDialog:new{
        title = name,
        buttons = {
            {
                {
                    text = _("Apply preset"),
                    callback = function()
                        local current = getSettings()
                        local preset = current.saved_presets and current.saved_presets[name]

                        if preset then
                            local updated = applySavedPreset(current, preset)
                            saveSettings(updated)
                        end

                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showInfo(_("Preset applied."))
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Overwrite with current settings"),
                    callback = function()
                        local current = getSettings()
                        current.saved_presets = current.saved_presets or {}
                        current.saved_presets[name] = makePresetFromSettings(current)
                        saveSettings(current)

                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSavedPresetsMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Delete preset"),
                    callback = function()
                        local current = getSettings()
                        if current.saved_presets then
                            current.saved_presets[name] = nil
                        end
                        saveSettings(current)

                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSavedPresetsMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSavedPresetsMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showSavedPresetsMenu()
    local settings = getSettings()
    local names = presetNames(settings)
    local dialog
    local buttons = {
        {
            {
                text = _("Save current settings as a new preset"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:nextTick(function()
                        self:showSavePresetDialog()
                    end)
                end,
            },
        },
    }

    if #names == 0 then
        table.insert(buttons, {
            {
                text = _("No saved presets yet."),
                enabled = false,
            },
        })
    else
        for _, name in ipairs(names) do
            table.insert(buttons, {
                {
                    text = name,
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSavedPresetActions(name)
                        end)
                    end,
                },
            })
        end
    end

    table.insert(buttons, {
        {
            text = _("← Back"),
            callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    self:showPresetsMenu()
                end)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Saved presets"),
        buttons = buttons,
    }

    UIManager:show(dialog)
end

function BookShowcase:showPresetsMenu()
    local settings = getSettings()
    local dialog

    dialog = ButtonDialog:new{
        title = _("Templates & saved presets"),
        buttons = {
            {
                {
                    text = _("Built-in template: ") .. templateLabel(settings.template),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showTemplateMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Saved presets"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSavedPresetsMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSettings()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showFormattingMenu()
    local settings = getSettings()
    local dialog

    local function toggle(key)
        settings[key] = not settings[key]
        saveSettings(settings)
        UIManager:close(dialog)
        UIManager:nextTick(function()
            self:showFormattingMenu()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Text, review & footer"),
        buttons = {
            {
                {
                    text = _("Show labels: ") .. onOff(settings.show_labels),
                    callback = function() toggle("show_labels") end,
                },
            },
            {
                {
                    text = _("Metadata spacing: ") .. spacingLabel(settings.spacing),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSpacingMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Description length: ") .. lengthLabel(settings.description_length),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showLengthMenu("description")
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Read full description action: ") .. onOff(settings.description_read_more),
                    callback = function() toggle("description_read_more") end,
                },
            },
            {
                {
                    text = _("Review length: ") .. lengthLabel(settings.review_length),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showLengthMenu("review")
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Review style: ") .. reviewStyleLabel(settings.review_style),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showReviewStyleMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Hide ‘Unknown author’: ") .. onOff(settings.hide_unknown_author),
                    callback = function() toggle("hide_unknown_author") end,
                },
            },
            {
                {
                    text = _("Short review in social card: ") .. onOff(settings.social_review_short),
                    callback = function() toggle("social_review_short") end,
                },
            },
            {
                {
                    text = _("Footer style: ") .. footerStyleLabel(settings.footer_style),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showFooterStyleMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Footer position: ") .. footerPositionLabel(settings.footer_position),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showFooterPositionMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Automatic finished footer: ") .. onOff(settings.auto_finished_footer),
                    callback = function() toggle("auto_finished_footer") end,
                },
            },
            {
                {
                    text = _("Default footer"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showFooterTextDialog()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showContentMenu()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showContentMenu()
    local dialog

    dialog = ButtonDialog:new{
        title = _("Content"),
        buttons = {
            {
                {
                    text = _("Choose fields"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showVisibilityMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Field order"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showOrderMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Text, review & footer"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showFormattingMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSettings()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showAbout()
    self:showInfo(
        _("Book Showcase")
        .. "\n\n"
        .. _("Version: ") .. PLUGIN_VERSION
        .. "\n"
        .. _("Author: ") .. PLUGIN_AUTHOR
        .. "\n\n"
        .. _("Book Showcase creates a customisable book-card popup from the information already stored in KOReader.")
        .. "\n\n"
        .. _("What it can do") .. ":\n"
        .. "• " .. _("Open from a book long-press menu in Library and History.") .. "\n"
        .. "• " .. _("Display the local cover, title, author, series, tags, description, rating, review and footer.") .. "\n"
        .. "• " .. _("Read existing KOReader reading data, including progress, status, status badge, finished date, reading time, pages read, reading days, reading pace, notes, highlights and last-opened date.") .. "\n"
        .. "• " .. _("Show or hide individual fields and arrange the visible fields in your preferred order.") .. "\n"
        .. "• " .. _("Use built-in templates or save your own presets for different card designs, including a Finished Book summary.") .. "\n"
        .. "• " .. _("Long-press an opened showcase to edit rating, review, footer, status or favourite quote; use Read full description to view the unshortened synopsis.") .. "\n"
        .. "• " .. _("Use Presentation mode with Balanced, Cover focus or Details focus screenshot layouts for a clean full-screen card.") .. "\n"
        .. "• " .. _("Add an optional favourite quote to a finished-book card from the opened showcase long-press menu.") .. "\n"
        .. "• " .. _("Preview the current showcase layout directly from the settings screen using the last showcased book.") .. "\n"
        .. "• " .. _("Adjust popup size, cover controls, background themes, screenshot layout, spacing, alignment, borders, colours, labels, review style and footer position.") .. "\n"
        .. "• " .. _("Use a global footer, a custom footer for one specific book, or an automatic finished-reading footer; Finished Book hides default footers unless a book-specific footer is set.") .. "\n"
        .. "• " .. _("Use safe text-based rating styles: stars, hearts or dots.")
        .. "\n\n"
        .. _("Data and safety") .. ":\n"
        .. "• " .. _("Uses existing KOReader metadata, reading statistics and cover data.") .. "\n"
        .. "• " .. _("Does not modify the book file itself.") .. "\n"
        .. "• " .. _("Back up and restore Book Showcase settings, colours and saved presets from Tools & reset.") .. "\n"
        .. "• " .. _("Reading statistics are displayed only when KOReader has recorded them for that book.")
        .. "\n\n"
        .. _("Requirements") .. ":\n"
        .. "• " .. _("Statistics fields require KOReader's Reading Statistics plugin to be enabled and to have recorded activity for the book.") .. "\n"
        .. "• " .. _("Empty metadata and zero-value statistics are hidden automatically.")
        .. "\n\n"
        .. _("Version history") .. ":\n"
        .. "• " .. _("Version 1.1.0 — Added direct Background theme controls (Paper, Warm paper, Slate and Night), cover zoom lock, Read full description, clean completion badges, automatic empty-section cleanup and screenshot layout choices for Presentation mode.") .. "\n"
        .. "• " .. _("Version 1.1.0 — Added Favourite Quote: save one optional quote for a book and show it on the Finished Book card.") .. "\n"
        .. "• " .. _("Version 1.1.0 — Restored the stable Showcase Actions menu and deferred its opening until after the Android long-press gesture has finished.") .. "\n"
        .. "• " .. _("Version 1.1.0 — Finished Book is now a cleaner completion card: title, author, rating, finish date, total pages, concise reading summary, description and review; default footers are hidden unless set for that book.") .. "\n"
        .. "• " .. _("Version 1.0.0 — Initial release.")
    )
end

function BookShowcase:showGeneralMenu()
    local dialog

    dialog = ButtonDialog:new{
        title = _("Tools & reset"),
        buttons = {
            {
                {
                    text = _("Back up settings"),
                    callback = function()
                        local ok, err = saveSettingsBackup()
                        UIManager:close(dialog)
                        if ok then
                            self:showInfo(_("Settings backup saved."))
                        else
                            self:showInfo(_("Could not save backup: ") .. tostring(err))
                        end
                    end,
                },
            },
            {
                {
                    text = _("Restore settings backup"),
                    callback = function()
                        local restored, err = loadSettingsBackup()
                        UIManager:close(dialog)
                        if restored then
                            saveSettings(restored)
                            self:showInfo(_("Settings restored from backup."))
                        else
                            self:showInfo(_("Could not restore backup: ") .. tostring(err))
                        end
                    end,
                },
            },
            {
                {
                    text = _("Reset all settings"),
                    callback = function()
                        saveSettings(defaultSettings())
                        UIManager:close(dialog)
                        self:showInfo(_("Book Showcase settings reset."))
                    end,
                },
            },
            {
                {
                    text = _("← Back"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showSettings()
                        end)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end


function BookShowcase:rememberPreviewBook(file)
    if file and DocumentRegistry:hasProvider(file) then
        G_reader_settings:saveSetting(PREVIEW_BOOK_KEY, file)

        if G_reader_settings.flush then
            G_reader_settings:flush()
        end
    end
end

function BookShowcase:showPreviewShowcase()
    local file = G_reader_settings:readSetting(PREVIEW_BOOK_KEY)

    if not file or file == "" then
        self:showInfo(_("No preview book yet.") .. "\n\n" .. _("Open Book Showcase from any book once, then come back here to preview your current settings."))
        return
    end

    if lfs.attributes(file, "mode") ~= "file" or not DocumentRegistry:hasProvider(file) then
        self:showInfo(_("The previous preview book is no longer available.") .. "\n\n" .. _("Open Book Showcase from another book first."))
        return
    end

    self:showBookShowcase(file, nil)
end

function BookShowcase:showSettings()
    local dialog

    dialog = ButtonDialog:new{
        title = _("Book Showcase settings"),
        buttons = {
            {
                {
                    text = _("Preview showcase"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showPreviewShowcase()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Templates & saved presets"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showPresetsMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Appearance"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAppearanceMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Content"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showContentMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Tools & reset"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showGeneralMenu()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("About"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            self:showAbout()
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
end

function BookShowcase:showTextShowcase(title, caption)
    UIManager:show(InfoMessage:new{
        text = title .. (caption ~= "" and "\n\n" .. caption or ""),
    })
end

function BookShowcase:showBookShowcase(file, book_props, presentation_mode)
    self:rememberPreviewBook(file)

    local doc_settings = DocSettings:open(file)
    local saved_props = doc_settings:readSetting("doc_props") or {}
    local summary = doc_settings:readSetting("summary") or {}

    local custom_props = {}
    local custom_metadata_file = DocSettings:findCustomMetadataFile(file)

    if custom_metadata_file then
        local custom_settings = DocSettings.openSettingsFile(custom_metadata_file)
        custom_props = custom_settings:readSetting("custom_props") or {}
    end

    book_props = book_props or {}
    local showcase_overrides = summary.bookshowcase_overrides or {}

    local function prop(key)
        -- These are Book Showcase-only overrides. They do not overwrite the
        -- original EPUB/PDF metadata or KOReader's general book information.
        if showcase_overrides[key] ~= nil and showcase_overrides[key] ~= "" then
            return showcase_overrides[key]
        end
        return custom_props[key]
            or book_props[key]
            or saved_props[key]
    end

    local global_settings = getSettings()
    local book_template = cleanText(summary.bookshowcase_template)
    local settings = book_template and buildTemplateSettings(book_template, global_settings) or global_settings

    local title = textOrDefault(
        prop("title") or book_props.display_title or saved_props.display_title,
        fileTitle(file)
    )

    local description = cleanText(prop("description"))

    if description then
        description = util.htmlToPlainTextIfHtml(description)
    end

    local raw_status = cleanText(summary.status)
    local status = raw_status

    if status == "complete" then
        status = _("Finished reading")
    elseif status == "abandoned" then
        status = _("On hold")
    elseif status == "reading" then
        status = _("Reading")
    end

    -- Only read the statistics SQLite database when one of its fields is
    -- enabled. This keeps normal cover/review cards quick to open.
    local stats = {}
    if hasVisibleStatistics(settings) then
        stats = self:getBookStatistics(
            file,
            isVisible(settings, "stat_days") or isVisible(settings, "reading_pace")
        ) or {}
    end

    local per_book_footer = cleanText(summary.bookshowcase_footer)
    local footer = nil

    if settings.template == "finished" then
        -- Finished Book is intended to be a clean share/show-off card.
        -- Do not show the global/default footer or the automatic finished
        -- footer here; only show a footer if the user explicitly entered one
        -- for this specific book.
        footer = per_book_footer
    else
        footer = per_book_footer
            or settings.footer_text
            or "#BookShowcase"

        if settings.auto_finished_footer and raw_status == "complete" then
            footer = appendUniqueFooterLine(footer, finishedFooterText(summary))
        end
    end

    local values = {
        title = title,
        author = (function()
            local author = cleanText(prop("authors") or prop("author"))
            if author then
                return author
            end
            if settings.hide_unknown_author then
                return nil
            end
            return _("Unknown author")
        end)(),
        series = cleanText(prop("series")),
        series_index = cleanText(prop("series_index")),
        language = cleanText(prop("language")),
        keywords = cleanText(prop("keywords")),
        description = description and formatLength(description, settings.description_length) or nil,
        description_full = description,
        description_has_more = description and settings.description_read_more
            and formatLength(description, settings.description_length) ~= description or false,
        pages = cleanText(prop("pages") or doc_settings:readSetting("doc_pages")),
        progress = getProgressText(doc_settings, summary),
        status = status,
        status_badge = settings.show_completion_badge and statusBadgeText(raw_status, status) or nil,
        completion_badge = settings.show_completion_badge and statusBadgeText(raw_status, status) or nil,
        finished_date = cleanText(summary.bookshowcase_finished_date)
            or completionDateText(summary)
            or (raw_status == "complete" and formatDate(stats.last_open) or nil),

        stat_time = formatDuration(stats.total_read_time),
        stat_pages = stats.total_read_pages and stats.total_read_pages > 0
            and tostring(stats.total_read_pages)
            or nil,
        stat_days = stats.days and stats.days > 0
            and tostring(stats.days)
            or nil,
        reading_pace = readingPaceText(stats),
        stat_highlights = stats.highlights and stats.highlights > 0
            and tostring(stats.highlights)
            or nil,
        stat_notes = stats.notes and stats.notes > 0
            and tostring(stats.notes)
            or nil,
        stat_last_open = formatDate(stats.last_open),

        rating = ratingStars(summary.rating, settings.rating_style),
        favourite_quote = (function()
            local quote = cleanText(summary.bookshowcase_favourite_quote)
            if not quote then
                return nil
            end
            -- A card should remain shareable on one screen. The full quote is
            -- retained in the editor; this is only the display length.
            return truncateText(quote, 360)
        end)(),
        review = (function()
            local review = cleanText(summary.note)
            if not review then
                return nil
            end
            return formatLength(review, settings.review_length)
        end)(),
        footer = footer,
    }

    -- Avoid repeating the same meaning in a compact card. A completed book
    -- already says "Finished reading", so a separate "100% read" line adds no value.
    if raw_status == "complete" and values.progress == "100% read" then
        values.progress = nil
    end

    -- Keep the badge as the compact status indicator. If both are enabled,
    -- hide the repeated full reading status in compact mode.
    if values.completion_badge then
        values.status_badge = nil
    end
    if values.status_badge and values.status and not settings.show_labels then
        values.status = nil
    end

    -- When pages read equals the total page count, retain the more useful total
    -- page count and hide the duplicate reading-statistic line.
    local total_pages = tonumber(tostring(values.pages or ""):match("%d+"))
    if total_pages and tonumber(values.stat_pages) == total_pages then
        values.stat_pages = nil
    end

    local caption = buildPrettyCaption(settings, values)
    local cover = BookInfo.getCoverImage({}, nil, file)

    if not cover then
        self:showTextShowcase(title, caption)
        return
    end

    local showcase_bgcolor, showcase_fgcolor = themeColors(settings)

    UIManager:show(ShowcaseViewer:new{
        image = cover,
        image_disposable = true,
        -- Presentation mode removes the surrounding title bar and fills the
        -- screen, giving the user a clean card that can be shown or captured
        -- without the Library/History screen behind it.
        fullscreen = presentation_mode or settings.popup_size == "fullscreen",
        with_title_bar = not presentation_mode and settings.show_title_bar,
        title_text = (not presentation_mode and settings.show_title_bar) and title or "",
        showcase_caption = caption,
        showcase_cover_height_ratio = (function()
            if presentation_mode and settings.presentation_layout == "cover_focus" then
                return math.max(coverHeightRatio(settings.cover_size), 0.38)
            elseif presentation_mode and settings.presentation_layout == "details_focus" then
                return math.min(coverHeightRatio(settings.cover_size), 0.20)
            end
            return coverHeightRatio(settings.cover_size)
        end)(),
        showcase_font_size = densityFontSize(settings.card_density),
        showcase_text_alignment = settings.template == "finished" and "left"
            or settings.text_alignment or "left",
        showcase_bgcolor = showcase_bgcolor,
        showcase_fgcolor = showcase_fgcolor,
        showcase_popup_size = presentation_mode and "fullscreen" or (settings.popup_size or "large"),
        showcase_border_size = presentation_mode and 0 or popupBorderSize(settings.popup_border),
        showcase_lock_cover_zoom = settings.cover_zoom_locked ~= false,
        showcase_presentation_layout = settings.presentation_layout or "balanced",
        showcase_presentation_mode = presentation_mode or false,
        buttons_visible = false,
        scale_factor = 0,
        showcase_action_callback = function(viewer)
            self:showShowcaseActions(viewer, file, book_props)
        end,
    })
end

function BookShowcase:init()
    self.ui.menu:registerToMainMenu(self)

    local function addDialogButtons(target, row_id, row_func)
        if not target then
            return
        end

        target.file_dialog_added_buttons = target.file_dialog_added_buttons or { index = {} }

        if target.file_dialog_added_buttons.index[row_id] == nil then
            table.insert(target.file_dialog_added_buttons, row_func)
            target.file_dialog_added_buttons.index[row_id] = #target.file_dialog_added_buttons
        end
    end

    local function showcaseButtons(file, is_file, book_props)
        -- Library/File Manager passes is_file. History may not use the same
        -- flag path, so we rely on DocumentRegistry to confirm it is a book.
        if not file or not DocumentRegistry:hasProvider(file) then
            return nil
        end

        return {
            {
                text = _("Open Showcase"),
                callback = function()
                    self:closeLongPressDialog()

                    UIManager:nextTick(function()
                        self:showBookShowcase(file, book_props)
                    end)
                end,
            },
        }
    end

    -- Normal Library/File Manager long-press menu.
    FileManager:addFileDialogButtons("bookshowcase", showcaseButtons)

    -- History uses its own BookList context-menu manager, so register the
    -- same buttons there as well.
    if self.ui and self.ui.history then
        addDialogButtons(self.ui.history, "bookshowcase", showcaseButtons)
    end
end

function BookShowcase:addToMainMenu(menu_items)
    menu_items.bookshowcase_settings = {
        text = _("Book Showcase settings"),
        callback = function()
            self:showSettings()
        end,
    }
end

return BookShowcase