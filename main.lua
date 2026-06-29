--[[
    Lockscreen Plugin for KOReader

    Displays randomised compositions of wallpaper images on the sleep screen.

    License: GNU AGPL v3
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local Screen          = Device.screen
local Blitbuffer      = require("ffi/blitbuffer")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local logger          = require("logger")
local _               = require("gettext")

local Kosmolitifier = WidgetContainer:extend {
    name        = "kosmolitifier",
    is_doc_only = false,
}

-- Returns the directory this source file lives in.
function Kosmolitifier:getPluginDir()
    local src = debug.getinfo(2, "S").source
    if src:find("^@") then
        return src:gsub("^@(.*)/[^/]*", "%1")
    end
end

function Kosmolitifier:init()
    self.ui.menu:registerToMainMenu(self)
    self:patchScreensaver()
end

function Kosmolitifier:addToMainMenu(menu_items)
    menu_items.kosmolitifier = {
        text = _("Kosmolit Lockscreen"),
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
        sorting_hint = "tools",
    }
end

function Kosmolitifier:getSubMenuItems()
    -- Reserved for future settings (e.g. composition style override, speed)
    return {}
end

function Kosmolitifier:patchScreensaver()
    local plugin_instance = self
    local Screensaver = require("ui/screensaver")

    -- Guard against double-patching
    if not Screensaver._orig_show_before_kosmolit then
        Screensaver._orig_show_before_kosmolit = Screensaver.show
    end

    Screensaver.show = function(screensaver_instance)
        if screensaver_instance.screensaver_type == "kosmolit" then
            logger.dbg("Kosmolitifier: kosmolit screensaver activated")

            -- Close any existing screensaver widget
            if screensaver_instance.screensaver_widget then
                UIManager:close(screensaver_instance.screensaver_widget)
                screensaver_instance.screensaver_widget = nil
            end

            Device.screen_saver_mode = true

            -- Normalise rotation to portrait upright
            local rotation_mode = Screen:getRotationMode()
            Device.orig_rotation_mode = rotation_mode
            local bit = require("bit")
            if bit.band(Device.orig_rotation_mode, 1) == 1 then
                Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
            else
                Device.orig_rotation_mode = nil
            end

            -- Build the composition widget
            local ok, result = pcall(function()
                local composer = require("composer")
                return composer:create(plugin_instance)
            end)

            local composition_widget = ok and result or nil

            if composition_widget then
                screensaver_instance.screensaver_widget = ScreenSaverWidget:new {
                    widget        = composition_widget,
                    background    = Blitbuffer.COLOR_WHITE,
                    covers_fullscreen = true,
                }
                screensaver_instance.screensaver_widget.modal    = true
                screensaver_instance.screensaver_widget.dithered = true

                UIManager:show(screensaver_instance.screensaver_widget, "full")
                logger.dbg("Kosmolitifier: widget displayed")
            else
                logger.warn("Kosmolitifier: composer failed, falling back to default screensaver")
                if not ok then logger.warn("Kosmolitifier error: " .. tostring(result)) end
                screensaver_instance.screensaver_type = "disable"
                Screensaver._orig_show_before_kosmolit(screensaver_instance)
            end
        else
            Screensaver._orig_show_before_kosmolit(screensaver_instance)
        end
    end

    -- Inject "Kosmolit" option into the Sleep screen > Wallpaper menu
    if not _G._orig_dofile_before_kosmolit then
        local orig_dofile = dofile
        _G._orig_dofile_before_kosmolit = orig_dofile

        _G.dofile = function(filepath)
            local result = orig_dofile(filepath)

            if filepath and filepath:match("screensaver_menu%.lua$") then
                logger.dbg("Kosmolitifier: patching screensaver menu")

                if result and result[1] and result[1].sub_item_table then
                    local wallpaper_submenu = result[1].sub_item_table

                    local kosmolit_item = {
                        text = _("Kosmolit (randomised wallpaper)"),
                        checked_func = function()
                            return G_reader_settings:readSetting("screensaver_type") == "kosmolit"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting("screensaver_type", "kosmolit")
                        end,
                        radio = true,
                    }

                    table.insert(wallpaper_submenu, 6, kosmolit_item)
                    logger.dbg("Kosmolitifier: menu item injected")
                end

                _G.dofile = orig_dofile
                _G._orig_dofile_before_kosmolit = nil
            end

            return result
        end
    end
end

return Kosmolitifier
