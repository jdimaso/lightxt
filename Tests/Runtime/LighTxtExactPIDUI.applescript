-- Exact-PID System Events fallback for the signed Release runtime pass.
--
-- The standalone Swift driver deliberately refuses to target an app by name,
-- but a one-off unsigned helper does not inherit Accessibility trust on every
-- developer Mac. This script keeps the same invariant while letting the
-- already-authorized host ask System Events to operate on one Unix PID only.

on run argv
    if (count of argv) < 2 then error "Usage: osascript LighTxtExactPIDUI.applescript <command> <pid> [arguments]"
    set commandName to item 1 of argv
    set targetPID to (item 2 of argv) as integer

    tell application "System Events"
        if not (exists first application process whose unix id is targetPID) then error "No application process for PID " & targetPID
        if commandName is "dump" then
            set maximumElements to 4000
            if (count of argv) > 2 then set maximumElements to (item 3 of argv) as integer
            return my dumpWindow(targetPID, maximumElements)
        else if commandName is "wait-text" then
            if (count of argv) < 3 then error "wait-text requires a query"
            set queryText to item 3 of argv
            set timeoutSeconds to 30
            if (count of argv) > 3 then set timeoutSeconds to (item 4 of argv) as real
            return my waitForText(targetPID, queryText, timeoutSeconds, false)
        else if commandName is "wait-missing-text" then
            if (count of argv) < 3 then error "wait-missing-text requires a query"
            set queryText to item 3 of argv
            set timeoutSeconds to 30
            if (count of argv) > 3 then set timeoutSeconds to (item 4 of argv) as real
            return my waitForText(targetPID, queryText, timeoutSeconds, true)
        else if commandName is "resize" then
            if (count of argv) < 4 then error "resize requires width and height"
            set targetProcess to first application process whose unix id is targetPID
            set size of window 1 of targetProcess to {(item 3 of argv) as integer, (item 4 of argv) as integer}
            delay 0.15
            return my frameText(window 1 of targetProcess)
        else if commandName is "window-frame" then
            set targetProcess to first application process whose unix id is targetPID
            return my frameText(window 1 of targetProcess)
        else if commandName is "frame" then
            if (count of argv) < 3 then error "frame requires a text query"
            set found to my findElement(targetPID, item 3 of argv)
            if found is missing value then error "No accessible element matched “" & item 3 of argv & "”"
            return my frameText(found)
        else if commandName is "click-text" then
            if (count of argv) < 3 then error "click-text requires a text query"
            set found to my findElement(targetPID, item 3 of argv)
            if found is missing value then error "No accessible element matched “" & item 3 of argv & "”"
            my activateElement(found, false, false)
            return "clicked"
        else if commandName is "select-text" then
            if (count of argv) < 3 then error "select-text requires a text query"
            set found to my findElement(targetPID, item 3 of argv)
            if found is missing value then error "No accessible element matched “" & item 3 of argv & "”"
            my activateElement(found, true, false)
            return "selected"
        else if commandName is "disclose-text" then
            if (count of argv) < 3 then error "disclose-text requires a text query"
            set found to my findElement(targetPID, item 3 of argv)
            if found is missing value then error "No accessible element matched “" & item 3 of argv & "”"
            set expandedFlag to true
            if (count of argv) > 3 and item 4 of argv is "false" then set expandedFlag to false
            my discloseElement(found, expandedFlag)
            if expandedFlag then return "expanded"
            return "collapsed"
        else if commandName is "set-value" then
            if (count of argv) < 4 then error "set-value requires current text and replacement"
            set found to my findElement(targetPID, item 3 of argv)
            if found is missing value then error "No accessible element matched “" & item 3 of argv & "”"
            my replaceElementValue(targetPID, found, item 4 of argv, true)
            return item 4 of argv
        else if commandName is "begin-value" then
            if (count of argv) < 4 then error "begin-value requires current text and replacement"
            set found to my findElement(targetPID, item 3 of argv)
            if found is missing value then error "No accessible element matched “" & item 3 of argv & "”"
            my replaceElementValue(targetPID, found, item 4 of argv, false)
            return item 4 of argv
        else if commandName is "assert-json-view-search" then
            if (count of argv) < 3 then error "assert-json-view-search requires a query"
            set queryText to item 3 of argv
            if (count characters of queryText) < 3 then error "assert-json-view-search requires at least three characters"
            set characterDelay to 0.3
            if (count of argv) > 3 then set characterDelay to (item 4 of argv) as real
            return my assertJSONViewSearch(targetPID, queryText, characterDelay)
        else if commandName is "menu" then
            if (count of argv) < 4 then error "menu requires top-level and item title"
            set targetProcess to first application process whose unix id is targetPID
            set topLevelTitle to item 3 of argv
            set itemTitle to item 4 of argv
            click menu bar item topLevelTitle of menu bar 1 of targetProcess
            delay 0.08
            click menu item itemTitle of menu 1 of menu bar item topLevelTitle of menu bar 1 of targetProcess
            return itemTitle
        else if commandName is "submenu" then
            if (count of argv) < 5 then error "submenu requires top-level, submenu, and item title"
            set targetProcess to first application process whose unix id is targetPID
            set topLevelTitle to item 3 of argv
            set submenuTitle to item 4 of argv
            set itemTitle to item 5 of argv
            click menu bar item topLevelTitle of menu bar 1 of targetProcess
            delay 0.08
            click menu item itemTitle of menu 1 of menu item submenuTitle of menu 1 of menu bar item topLevelTitle of menu bar 1 of targetProcess
            return itemTitle
        else
            error "Unknown exact-PID UI command: " & commandName
        end if
    end tell
end run

on assertJSONViewSearch(targetPID, queryText, characterDelay)
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPID
        set findButton to my findElement(targetPID, "Find")
        if findButton is missing value then error "The JSON window has no Find control"
        my activateElement(findButton, false, false)
        delay 0.15

        set frontmost of targetProcess to true
        keystroke "a" using command down
        repeat with queryCharacter in characters of queryText
            keystroke (queryCharacter as text)
            delay characterDelay
        end repeat
        delay 0.4

        set focusedElement to value of attribute "AXFocusedUIElement" of targetProcess
        set focusedSubrole to ""
        set focusedDescription to ""
        set focusedValue to ""
        try
            set focusedSubrole to subrole of focusedElement as text
        end try
        try
            set focusedDescription to description of focusedElement as text
        end try
        try
            set focusedValue to value of focusedElement as text
        end try
        if focusedSubrole is not "AXSearchField" or focusedDescription is not "Find" then
            error "Find lost first responder after an asynchronous JSON match"
        end if
        if focusedValue is not queryText then
            error "Only “" & focusedValue & "” remained in Find; later keys were diverted"
        end if

        if my findElement(targetPID, "FILE-BACKED VIEW") is missing value then
            error "JSON search switched the document out of View mode"
        end if
        if my findElement(targetPID, "JSON Explorer") is missing value then
            error "JSON Explorer disappeared while entering a search"
        end if
        if my findElement(targetPID, "saved") is missing value then
            error "Typing the search query mutated the document"
        end if
        return "JSON View search QA passed: query=“" & focusedValue & "”, first responder=Find, mode=FILE-BACKED VIEW, document=saved"
    end tell
end assertJSONViewSearch

on dumpWindow(targetPID, maximumElements)
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPID
        set outputLines to {}
        set allElements to entire contents of window 1 of targetProcess
        set emitted to 0
        repeat with wrappedElement in allElements
            if emitted >= maximumElements then exit repeat
            set emitted to emitted + 1
            set elementObject to contents of wrappedElement
            set end of outputLines to my describeElement(elementObject)
        end repeat
        return my joinLines(outputLines)
    end tell
end dumpWindow

on waitForText(targetPID, queryText, timeoutSeconds, shouldDisappear)
    set attempts to ((timeoutSeconds * 10) as integer) + 1
    repeat attempts times
        set found to my findElement(targetPID, queryText)
        if shouldDisappear and found is missing value then return queryText
        if (not shouldDisappear) and found is not missing value then return queryText
        delay 0.08
    end repeat
    if shouldDisappear then error "Accessible text still contained “" & queryText & "”"
    error "Accessible text never contained “" & queryText & "”"
end waitForText

on findElement(targetPID, queryText)
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPID
        set allElements to entire contents of window 1 of targetProcess
        repeat with wrappedElement in allElements
            set elementObject to contents of wrappedElement
            if my elementContains(elementObject, queryText) then return elementObject
        end repeat
    end tell
    return missing value
end findElement

on elementContains(elementObject, queryText)
    tell application "System Events"
        try
            if (name of elementObject as text) contains queryText then return true
        end try
        try
            if (description of elementObject as text) contains queryText then return true
        end try
        try
            if (value of elementObject as text) contains queryText then return true
        end try
        try
            if (help of elementObject as text) contains queryText then return true
        end try
        try
            if (value of attribute "AXIdentifier" of elementObject as text) contains queryText then return true
        end try
    end tell
    return false
end elementContains

on activateElement(found, preferSelection, ignorePress)
    tell application "System Events"
        set candidate to found
        repeat 7 times
            if preferSelection then
                try
                    set selected of candidate to true
                    return
                end try
                try
                    set value of attribute "AXSelected" of candidate to true
                    return
                end try
            end if
            if not ignorePress then
                try
                    perform action "AXPress" of candidate
                    return
                end try
                try
                    click candidate
                    return
                end try
            end if
            try
                set candidate to parent of candidate
            on error
                exit repeat
            end try
        end repeat
    end tell
    error "Matched element and ancestors could not be activated"
end activateElement

on discloseElement(found, expanded)
    tell application "System Events"
        set candidate to found
        repeat 7 times
            try
                set value of attribute "AXDisclosing" of candidate to expanded
                return
            end try
            try
                set candidate to parent of candidate
            on error
                exit repeat
            end try
        end repeat
    end tell
    error "Matched element and ancestors do not expose AXDisclosing"
end discloseElement

on replaceElementValue(targetPID, found, replacement, shouldCommit)
    tell application "System Events"
        set frontmost of first application process whose unix id is targetPID to true
        set candidate to found
        repeat 5 times
            try
                set focused of candidate to true
                set value of candidate to replacement
                if shouldCommit then key code 36 using {}
                return
            end try
            try
                set candidate to parent of candidate
            on error
                exit repeat
            end try
        end repeat
    end tell
    error "Matched element and ancestors do not accept a text value"
end replaceElementValue

on describeElement(elementObject)
    tell application "System Events"
        set roleText to "?"
        set subroleText to ""
        set nameText to ""
        set descriptionText to ""
        set valueText to ""
        set identifierText to ""
        try
            set roleText to role of elementObject as text
        end try
        try
            set subroleText to subrole of elementObject as text
        end try
        try
            set nameText to name of elementObject as text
        end try
        try
            set descriptionText to description of elementObject as text
        end try
        try
            set valueText to value of elementObject as text
        end try
        try
            set identifierText to value of attribute "AXIdentifier" of elementObject as text
        end try
        return roleText & ":" & subroleText & " id=" & identifierText & " frame=" & my frameText(elementObject) & " name=" & nameText & " description=" & descriptionText & " value=" & valueText
    end tell
end describeElement

on frameText(elementObject)
    tell application "System Events"
        try
            set elementPosition to position of elementObject
            set elementSize to size of elementObject
            return "x=" & item 1 of elementPosition & " y=" & item 2 of elementPosition & " width=" & item 1 of elementSize & " height=" & item 2 of elementSize
        on error
            return ""
        end try
    end tell
end frameText

on joinLines(theLines)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to linefeed
    set joined to theLines as text
    set AppleScript's text item delimiters to oldDelimiters
    return joined
end joinLines
