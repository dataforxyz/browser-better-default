import QtQuick
import QtQuick.Window
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
    id: root

    // Public host contract
    property var document: null
    property string editorBackend: ""
    readonly property string docsUrl: "https://github.com/dataforxyz/browser-better-default"
    property bool busy: false
    property bool dirty: false
    property bool autosave: true
    property bool onboardingSeen: false
    property var onboardingSelection: ({})
    readonly property var onboardingCandidates: {
        const enabledPatterns = new Set(draftRules.filter(rule => rule.enabled).map(rule => rule.pattern.trim()));
        return rawSuggestions.filter(item => item.detected && !enabledPatterns.has(item.pattern));
    }
    property bool allowAutosave: true
    property bool profileSyncEnabled: false
    property bool profileSyncLoaded: false
    property bool profileSyncBusy: false
    property string profileSyncStatus: ""
    property string setupProfileSyncStatus: ""
    property string defaultHandlerStatus: ""
    property string bridgeStatus: ""
    property bool bridgeBusy: false
    property bool bridgeFailed: false
    property bool defaultHandlerFailed: false
    property bool setupProfileSyncFailed: false
    property int editingPatternUid: -1
    // Scoped Omarchy theme surface — defaults track qs.Commons live and can be
    // overridden per-instance by a host window.
    property color foreground: Commons.Color.foreground
    property color background: Commons.Color.background
    property color accent: Commons.Color.accent
    property color urgent: Commons.Color.urgent
    property color muted: Commons.Color.muted
    property color popupBackground: Commons.Color.popups.background
    property color popupBorder: Commons.Color.popups.border
    property string fontFamily: Style.font.family
    property real contentPadding: 0
    readonly property string askLabel: "Always ask (show the menu)"
    readonly property string noneFoundLabel: "(no browsers found)"
    // View state (never mutates actual rule priority order)
    property string activeTab: "rules"
    // "rules" | "suggestions"
    property string searchQuery: ""
    onSearchQueryChanged: {
        if (selectingRules) selectedRules = {};
        rebuildVisibleRules();
    }
    property string suggestionSearch: ""
    property string suggestionSort: "recommended"
    property string suggestionKind: "all"
    property string editingSuggestionKey: ""
    property int suggestionPatternRevision: 0
    property string pendingSuggestionKey: ""
    property int lastAddedUid: -1
    property var suggestionUndo: null
    readonly property bool tracingUrl: /^(https?:\/\/\S+|mailto:\S+)$/i.test(searchQuery.trim())
    readonly property string traceRequest: tracingUrl
        ? JSON.stringify(Object.assign(buildSavePayload(draftRules, draftFallback), { url: searchQuery.trim() }))
        : ""
    readonly property var regexPatterns: {
        suggestionPatternRevision;
        const patterns = draftRules.map(rule => rule.pattern.trim());
        for (let i = 0; i < rawSuggestions.length; i++) {
            const raw = rawSuggestions[i];
            const edit = _suggestionEdits[suggestionKeyFor(raw, i)];
            patterns.push(String(edit && edit.pattern !== undefined ? edit.pattern : raw.pattern || "").trim());
        }
        return [...new Set(patterns.filter(pattern => pattern.startsWith("regex:")))];
    }
    property var invalidRegexPatterns: ({})
    property string validatedRegexSignature: "[]"
    property bool _manualSavePending: false
    onRegexPatternsChanged: regexValidationDelay.restart()
    Timer {
        id: regexValidationDelay
        interval: 180
        onTriggered: {
            if (root.regexPatterns.length === 0) {
                root.invalidRegexPatterns = ({});
                root.validatedRegexSignature = "[]";
                root.finishRegexValidation();
                return;
            }
            if (regexValidator.running) return;
            regexValidator.patterns = root.regexPatterns.slice();
            regexValidator.command = ["bash", "-c",
                'i=0; for pattern; do [[ "" =~ $pattern ]]; result=$?; if [[ $result == 2 ]]; then printf "%s\\n" "$i"; fi; i=$((i+1)); done; exit 0',
                "validate-rule-patterns"].concat(regexValidator.patterns.map(pattern => pattern.slice(6)));
            regexValidator.running = true;
        }
    }
    Process {
        id: regexValidator
        property var patterns: []
        stdout: StdioCollector { id: regexValidationOutput }
        onExited: function(code) {
            const signature = JSON.stringify(patterns);
            if (signature !== JSON.stringify(root.regexPatterns)) {
                regexValidationDelay.restart();
                return;
            }
            const invalid = {};
            if (code === 0) {
                for (const index of regexValidationOutput.text.trim().split("\n").filter(value => value !== ""))
                    invalid[patterns[Number(index)]] = true;
                root.invalidRegexPatterns = invalid;
                root.validatedRegexSignature = signature;
                root.finishRegexValidation();
            }
        }
    }
    property var traceResult: null
    property string traceError: ""
    property string sortMode: "priority" // "site" | "priority" | "pattern" | "target"
    property bool groupBySite: true
    property string filterMode: "all" // "all" | "enabled" | "disabled" | "private" | "conflicts"
    readonly property var ruleConflicts: {
        const firstByPattern = Object.create(null);
        const conflicts = Object.create(null);
        for (let i = 0; i < draftRules.length; i++) {
            const rule = draftRules[i];
            const pattern = rule.pattern.trim();
            if (!rule.enabled || !pattern || invalidPatternReason(pattern))
                continue;
            const earlier = firstByPattern[pattern];
            if (earlier === undefined) {
                firstByPattern[pattern] = i;
                continue;
            }
            const first = draftRules[earlier];
            conflicts[rule.uid] = (first.label === rule.label && first.isPrivate === rule.isPrivate
                ? "Duplicate of rule #" : "Same pattern as rule #") + (earlier + 1)
                + ". The earlier rule is tried first.";
        }
        return conflicts;
    }
    readonly property int ruleConflictCount: Object.keys(ruleConflicts).length
    property var expandedSites: ({})
    property bool selectingRules: false
    property var selectedRules: ({})
    property int selectionAnchor: -1
    property var pendingRemoval: []
    property var removalUndo: []
    property int dragRuleUid: -1
    property int dragTarget: -1
    property real dragPointerY: 0
    readonly property int selectedRuleCount: draftRules.filter(rule => selectedRules[rule.uid]).length
    readonly property bool canReorder: !groupBySite && sortMode === "priority" && filterMode === "all" && searchQuery.trim() === ""
    // Draft and document state
    property var browserTargets: []
    property var appTargets: []
    property var allTargets: []
    property var draftRules: []
    property string draftFallback: ""
    property var rawSuggestions: []
    // Internal synchronization & UI state
    property int _nextUid: 1
    property bool _hasLoadedDocument: false
    property string _lastRevision: ""
    property string _baselineSignature: ""
    property var _baselineRules: []
    property string _baselineFallback: ""
    property bool _awaitingSave: false
    property bool _automaticSave: false
    property bool _rescanInFlight: false
    property var _queuedBeginRule: null
    property var _suggestionEdits: ({
    })
    property var _stagedSuggestionKeys: ({
    })
    property int _pendingFocusUid: -1
    property bool _pendingSelectAll: false
    property string statusMessage: ""
    property bool statusIsWarning: false
    property bool statusShowRulesLink: false
    readonly property bool fallbackMissing: draftFallback !== "" && browserTargets.indexOf(draftFallback) === -1
    property int actionableSuggestionCount: 0
    readonly property int missingRuleCount: {
        var count = 0;
        for (var i = 0; i < draftRules.length; i++) {
            var lbl = String(draftRules[i].label || "");
            if (lbl !== "" && lbl !== noneFoundLabel && allTargets.indexOf(lbl) === -1)
                count++;

        }
        return count;
    }
    readonly property int incompleteRuleCount: draftRules.filter(rule => !rule.pattern.trim() || !rule.label.trim()
        || rule.label === noneFoundLabel || invalidPatternReason(rule.pattern)).length
    readonly property int invalidPrivateCount: {
        var count = 0;
        for (var i = 0; i < draftRules.length; i++) {
            if (draftRules[i].isPrivate && isAppTarget(draftRules[i].label))
                count++;

        }
        return count;
    }

    signal saveRequested(var rules, string fallback)
    signal rescanRequested()
    signal focusSyncRequested()
    signal draftSynced()
    signal sortChosen(string order)
    signal autosaveChosen(bool enabled)
    signal profileSyncToggled(bool enabled)
    signal profileSyncRequested()
    signal bridgeInstallRequested()
    signal draftDiscarded()
    signal onboardingDismissed()
    signal setupRequested(bool refreshOnly)
    signal traceRequested(string request)

    property bool _deferredAutosave: false
    onAllowAutosaveChanged: scheduleAutosave()

    Timer {
        id: autosaveDelay
        interval: 650
        onTriggered: {
            if (root.canAutosave())
                root.requestSave(true);
        }
    }

    function canAutosave() {
        return autosave && allowAutosave && dirty && !busy && _hasLoadedDocument
            && editingPatternUid < 0 && pendingRemoval.length === 0 && dragRuleUid < 0
            && validatedRegexSignature === JSON.stringify(regexPatterns)
            && draftRules.every(rule => rule.pattern.trim() && rule.label.trim()
                && rule.label !== noneFoundLabel && !invalidPatternReason(rule.pattern)
                && (!rule.isPrivate || !isAppTarget(rule.label)));
    }

    function scheduleAutosave() {
        autosaveDelay.stop();
        if (canAutosave())
            autosaveDelay.start();
    }

    onTraceRequestChanged: {
        traceResult = null;
        traceError = "";
        traceDelay.stop();
        if (traceRequest)
            traceDelay.start();
    }

    Timer {
        id: traceDelay
        interval: 240
        onTriggered: root.traceRequested(root.traceRequest)
    }

    function acceptTrace(request, result, error) {
        if (request !== traceRequest)
            return;
        traceResult = result;
        traceError = error;
    }

    function dismissOnboarding() {
        if (!onboardingSeen) {
            onboardingSeen = true;
            onboardingDismissed();
        }
    }

    function startRecommendedSetup() {
        onboardingSelection = {};
        if (editorBackend === "") {
            appSetupPopup.open();
            return;
        }
        systemSetupPopup.extras = false;
        systemSetupPopup.open();
    }

    function finishRecommendedSetup() {
        dismissOnboarding();
        appSetupPopup.close();
        systemSetupPopup.close();
        webappProfilesPopup.close();
    }

    function advanceAppSetup() {
        if (editorBackend === "") {
            finishRecommendedSetup();
            return;
        }
        appSetupPopup.close();
        systemSetupPopup.extras = true;
        systemSetupPopup.open();
    }

    function toggleOnboardingApp(item) {
        const next = Object.assign({}, onboardingSelection);
        if (next["pattern:" + item.pattern] === item.label)
            delete next["pattern:" + item.pattern];
        else
            next["pattern:" + item.pattern] = item.label;
        onboardingSelection = next;
    }

    function addOnboardingApps() {
        const chosen = onboardingCandidates.filter(item => onboardingSelection["pattern:" + item.pattern] === item.label);
        if (!chosen.length || busy)
            return;
        if (!addSuggestionRules(chosen))
            return;
        advanceAppSetup();
    }

    function traceStatus(status) {
        switch (status) {
        case "winner": return "Opens here";
        case "disabled": return "Disabled";
        case "unsupported": return "App skips this URL";
        case "unavailable": return "Target unavailable · chooser opens";
        default: return "Not reached";
        }
    }

    function chooseSort(order) {
        if (sortMode === order)
            return;
        sortMode = order;
        sortChosen(order);
        rebuildVisibleRules();
    }

    function toggleSite(site) {
        const next = Object.assign({}, expandedSites);
        next[site] = !expandedSites[site];
        expandedSites = next;
    }

    function toggleSelection(uids) {
        const next = Object.assign({}, selectedRules);
        const select = !uids.every(uid => next[uid]);
        for (const uid of uids) {
            if (select)
                next[uid] = true;
            else
                delete next[uid];
        }
        selectedRules = next;
    }

    function visibleSiteUids(site) {
        const uids = [];
        for (let i = 0; i < visibleRulesModel.count; i++) {
            const rule = visibleRulesModel.get(i);
            if (rule.siteName === site)
                uids.push(rule.uid);
        }
        return uids;
    }

    function selectWithModifier(uid, modifiers) {
        const shown = [];
        for (let i = 0; i < visibleRulesModel.count; i++) {
            const row = visibleRulesModel.get(i);
            if (row.groupCount < 2 || searchQuery.trim() || filterMode !== "all" || expandedSites[row.siteName])
                shown.push(row.uid);
        }
        const anchor = shown.indexOf(selectionAnchor);
        const clicked = shown.indexOf(uid);
        if (clicked < 0)
            return;
        if (modifiers & Qt.ShiftModifier) {
            const first = anchor < 0 ? clicked : anchor;
            const next = modifiers & Qt.ControlModifier ? Object.assign({}, selectedRules) : {};
            for (let i = Math.min(first, clicked); i <= Math.max(first, clicked); i++)
                next[shown[i]] = true;
            selectedRules = next;
            if (anchor < 0)
                selectionAnchor = uid;
        } else {
            const next = Object.assign({}, selectedRules);
            if (!selectingRules && anchor >= 0 && shown[anchor] !== uid)
                next[shown[anchor]] = true;
            if (next[uid])
                delete next[uid];
            else
                next[uid] = true;
            selectedRules = next;
            selectionAnchor = uid;
        }
        selectingRules = true;
    }

    function applyBulk(action, value) {
        if (busy || selectedRuleCount === 0)
            return;
        const invalidTarget = action === "target" && isAppTarget(value)
            && draftRules.some(rule => selectedRules[rule.uid] && rule.isPrivate);
        const invalidPrivate = action === "private" && value
            && draftRules.some(rule => selectedRules[rule.uid] && isAppTarget(rule.label));
        if (invalidTarget || invalidPrivate) {
            statusMessage = "Private rules need a browser target.";
            statusIsWarning = true;
            return;
        }
        draftRules = draftRules.map(rule => !selectedRules[rule.uid] ? rule : Object.assign({}, rule,
            action === "target" ? { label: value }
                : action === "private" ? { isPrivate: value } : { enabled: value }));
        statusMessage = "";
        statusIsWarning = false;
        recomputeDirty();
        rebuildVisibleRules();
        rebuildSuggestions();
    }

    function beginRule(pattern, label) {
        var pat = pattern !== undefined && pattern !== null ? String(pattern) : "";
        var lbl = label !== undefined && label !== null ? String(label).trim() : "";
        if (!_hasLoadedDocument && !document)
            _queuedBeginRule = {
            "pattern": pat,
            "label": lbl
        };

        _insertNewRule(pat, lbl, pat.trim() !== "");
    }

    function focusEditor() {
        if (_pendingFocusUid >= 0) {
            focusSyncRequested();
            return ;
        }
        if (activeTab === "rules") {
            if (searchField)
                searchField.forceActiveFocus();

        } else if (activeTab === "suggestions" && actionableSuggestionCount > 0) {
            suggestionSearchField.forceActiveFocus();
        }
    }

    function uniqueStrings(list, excludeSet) {
        var out = [];
        var seen = excludeSet ? Object.assign({
        }, excludeSet) : {
        };
        if (!Array.isArray(list))
            return out;

        for (var i = 0; i < list.length; i++) {
            var item = String(list[i] || "").trim();
            if (!item || seen[item])
                continue;

            seen[item] = true;
            out.push(item);
        }
        return out;
    }

    function isAppTarget(label) {
        var s = String(label || "");
        return s !== "" && appTargets.indexOf(s) !== -1;
    }

    function isMissingTarget(label) {
        var s = String(label || "");
        return s !== "" && s !== noneFoundLabel && allTargets.indexOf(s) === -1;
    }

    function invalidPatternReason(pattern) {
        var s = String(pattern || "");
        if (s.indexOf("|||") !== -1)
            return "Pattern cannot contain '|||'.";

        for (var i = 0; i < s.length; i++) {
            var code = s.charCodeAt(i);
            if (code < 32 || code === 127 || code === 133 || code === 8232 || code === 8233)
                return "Pattern contains unsupported control characters.";

        }
        var trimmed = s.trim();
        if (trimmed.startsWith("regex:") && Object.prototype.hasOwnProperty.call(invalidRegexPatterns, trimmed)
                && invalidRegexPatterns[trimmed] === true)
            return "Invalid regex pattern (Bash regular expression).";
        if (trimmed !== "" && trimmed.charAt(trimmed.length - 1) === "|")
            return "Pattern cannot end with '|'.";

        return "";
    }

    function ruleSite(pattern) {
        var text = String(pattern || "").trim();
        if (text.indexOf("regex:") === 0)
            return "Custom patterns";

        var match = text.match(/^(?:https?:\/\/)?([a-z0-9-]+(?:\.[a-z0-9-]+)+|localhost)(?=[:/?#]|$)/i);
        if (!match)
            return "Custom patterns";

        var host = match[1].toLowerCase();
        if (host.indexOf("www.") === 0)
            host = host.slice(4);

        return host;
    }

    function ruleTargetOptions(currentLabel) {
        var cur = String(currentLabel || "").trim();
        var opts = [];
        if (cur !== "" && cur !== noneFoundLabel && allTargets.indexOf(cur) === -1)
            opts.push({
            "value": cur,
            "label": cur,
            "tag": "missing"
        });

        for (var i = 0; i < browserTargets.length; i++) opts.push({
            "value": browserTargets[i],
            "label": browserTargets[i],
            "tag": ""
        })
        for (var j = 0; j < appTargets.length; j++) opts.push({
            "value": appTargets[j],
            "label": appTargets[j],
            "tag": "app"
        })
        if (opts.length === 0)
            opts.push({
            "value": noneFoundLabel,
            "label": noneFoundLabel,
            "tag": ""
        });

        return opts;
    }

    function fallbackTargetOptions() {
        var opts = [{
            "value": "",
            "label": askLabel,
            "tag": ""
        }];
        if (draftFallback !== "" && draftFallback !== noneFoundLabel && browserTargets.indexOf(draftFallback) === -1)
            opts.push({
            "value": draftFallback,
            "label": draftFallback,
            "tag": "missing"
        });

        for (var i = 0; i < browserTargets.length; i++) opts.push({
            "value": browserTargets[i],
            "label": browserTargets[i],
            "tag": ""
        })
        return opts;
    }

    function normalizeRuleInput(raw) {
        var obj = raw && typeof raw === "object" ? raw : {
        };
        var enabled = obj.enabled !== undefined ? !!obj.enabled : true;
        var pattern = obj.pattern !== undefined && obj.pattern !== null ? String(obj.pattern) : "";
        var label = obj.label !== undefined && obj.label !== null ? String(obj.label).trim() : "";
        var isPriv = !!obj["private"];
        return {
            "uid": _nextUid++,
            "enabled": enabled,
            "pattern": pattern,
            "label": label,
            "isPrivate": isPriv
        };
    }

    function cloneRuleList(list) {
        var out = [];
        for (var i = 0; i < list.length; i++) {
            out.push({
                "uid": list[i].uid,
                "enabled": !!list[i].enabled,
                "pattern": String(list[i].pattern || ""),
                "label": String(list[i].label || ""),
                "isPrivate": !!list[i].isPrivate
            });
        }
        return out;
    }

    function buildSavePayload(rulesList, fallbackValue) {
        var outRules = [];
        for (var i = 0; i < rulesList.length; i++) {
            var r = rulesList[i];
            var pat = String(r.pattern || "").trim();
            var lbl = String(r.label || "").trim();
            if (!pat || !lbl || lbl === noneFoundLabel)
                continue;

            outRules.push({
                "enabled": !!r.enabled,
                "pattern": pat,
                "label": lbl,
                "private": !!r.isPrivate
            });
        }
        var fb = String(fallbackValue || "").trim();
        if (fb === askLabel || fb === noneFoundLabel)
            fb = "";

        return {
            "rules": outRules,
            "fallback": fb
        };
    }

    function payloadSignature(rulesList, fallbackValue) {
        return JSON.stringify(buildSavePayload(rulesList, fallbackValue));
    }

    function suggestionKeyFor(item, index) {
        var pat = String(item.pattern || "").trim();
        var lbl = String(item.label || "").trim();
        var priv = item["private"] ? "1" : "0";
        return pat + "\u0000" + lbl + "\u0000" + priv + "\u0000" + String(index);
    }

    function findRuleIndexByUid(uid) {
        for (var i = 0; i < draftRules.length; i++) {
            if (draftRules[i].uid === uid)
                return i;

        }
        return -1;
    }

    function recomputeDirty() {
        dirty = payloadSignature(draftRules, draftFallback) !== _baselineSignature;
        scheduleAutosave();
    }

    function applyDocument(doc) {
        var safeDoc = doc && typeof doc === "object" ? doc : {
        };
        var browsers = uniqueStrings(safeDoc.browsers, null);
        var browserSet = {
        };
        for (var i = 0; i < browsers.length; i++) browserSet[browsers[i]] = true
        var rawApps = Array.isArray(safeDoc.apps) ? safeDoc.apps : (Array.isArray(safeDoc.app) ? safeDoc.app : []);
        var apps = uniqueStrings(rawApps, browserSet);
        var combined = browsers.concat(apps);
        browserTargets = browsers;
        appTargets = apps;
        allTargets = combined;
        rawSuggestions = Array.isArray(safeDoc.suggestions) ? safeDoc.suggestions : [];
        var incomingRevision = safeDoc.revision !== undefined && safeDoc.revision !== null ? String(safeDoc.revision) : "";
        var incomingRules = [];
        if (Array.isArray(safeDoc.rules)) {
            for (var r = 0; r < safeDoc.rules.length; r++) incomingRules.push(normalizeRuleInput(safeDoc.rules[r]))
        }
        var incomingFallback = safeDoc.fallback !== undefined && safeDoc.fallback !== null ? String(safeDoc.fallback).trim() : "";
        var incomingSig = payloadSignature(incomingRules, incomingFallback);
        var wasRescan = _rescanInFlight;
        var wasFirstLoad = !_hasLoadedDocument;
        var keepSavedDraft = _awaitingSave
            && payloadSignature(draftRules, draftFallback) === incomingSig;
        var shouldReplaceDraft = wasFirstLoad || _awaitingSave || !dirty || (incomingRevision !== _lastRevision && payloadSignature(draftRules, draftFallback) === incomingSig);
        if (wasFirstLoad && ["priority", "site", "pattern", "target"].includes(doc.sort))
            sortMode = doc.sort;
        if (wasFirstLoad)
            autosave = safeDoc.autosave !== false;
        onboardingSeen = onboardingSeen || safeDoc.onboarding_seen === true;
        _hasLoadedDocument = true;
        _lastRevision = incomingRevision;
        _baselineRules = cloneRuleList(incomingRules);
        _baselineFallback = incomingFallback;
        _baselineSignature = incomingSig;
        if (shouldReplaceDraft) {
            var savedSuccess = _awaitingSave;
            _awaitingSave = false;
            _automaticSave = false;
            _rescanInFlight = false;
            if (!keepSavedDraft) {
                suggestionUndo = null;
                lastAddedUid = -1;
                pendingSuggestionKey = "";
                editingSuggestionKey = "";
                selectedRules = {};
                selectingRules = false;
                editingPatternUid = -1;
                _stagedSuggestionKeys = ({});
                _suggestionEdits = ({});
                draftRules = cloneRuleList(incomingRules);
                draftFallback = incomingFallback;
            }
            if (wasFirstLoad && _queuedBeginRule) {
                var queued = _queuedBeginRule;
                _queuedBeginRule = null;
                _insertNewRule(queued.pattern, queued.label, queued.pattern.trim() !== "");
            }
            draftSynced();
            recomputeDirty();
            if (savedSuccess) {
                statusMessage = "";
                statusIsWarning = false;
                savedIndicator.restart();
            }
        } else {
            // Preserve unsaved draft edits (e.g. after Rescan) while refreshing targets & suggestions.
            if (_rescanInFlight) {
                _rescanInFlight = false;
                statusMessage = "Refreshed " + browserTargets.length + " browser profiles and " + appTargets.length + " apps.";
                statusIsWarning = false;
                statusShowRulesLink = false;
            }
            recomputeDirty();
        }
        if (wasRescan && !savedSuccess) {
            _rescanInFlight = false;
            statusMessage = "Refreshed " + browserTargets.length + " browser profiles and " + appTargets.length + " apps.";
            statusIsWarning = false;
            statusShowRulesLink = false;
        }
        rebuildVisibleRules();
        rebuildSuggestions();
    }

    function rebuildVisibleRules() {
        var query = searchQuery.trim().toLowerCase();
        var rows = [];
        for (var i = 0; i < draftRules.length; i++) {
            var r = draftRules[i];
            var allowed = true;
            if (filterMode === "enabled")
                allowed = r.enabled;
            else if (filterMode === "disabled")
                allowed = !r.enabled;
            else if (filterMode === "private")
                allowed = r.isPrivate;
            else if (filterMode === "conflicts")
                allowed = !!ruleConflicts[r.uid];
            if (!allowed)
                continue;

            var patLower = String(r.pattern || "").toLowerCase();
            var lblLower = String(r.label || "").toLowerCase();
            if (query !== "" && patLower.indexOf(query) === -1 && lblLower.indexOf(query) === -1)
                continue;

            rows.push({
                "uid": r.uid,
                "actualIndex": i,
                "enabled": r.enabled,
                "pattern": r.pattern,
                "label": r.label,
                "isPrivate": r.isPrivate,
                "siteName": ruleSite(r.pattern)
            });
        }
        if (sortMode === "site")
            rows.sort(function(a, b) {
                const aCustom = a.siteName === "Custom patterns";
                const bCustom = b.siteName === "Custom patterns";
                if (aCustom !== bCustom)
                    return aCustom ? 1 : -1;
                return a.siteName.localeCompare(b.siteName) || a.actualIndex - b.actualIndex;
            });
        else if (sortMode === "pattern")
            rows.sort(function(a, b) {
            var cmp = String(a.pattern || "").toLowerCase().localeCompare(String(b.pattern || "").toLowerCase());
            return cmp !== 0 ? cmp : (a.actualIndex - b.actualIndex);
        });
        else if (sortMode === "target")
            rows.sort(function(a, b) {
            var cmp = String(a.label || "").toLowerCase().localeCompare(String(b.label || "").toLowerCase());
            return cmp !== 0 ? cmp : (a.actualIndex - b.actualIndex);
        });
        const sites = new Map();
        if (groupBySite) {
            for (const row of rows) {
                if (!sites.has(row.siteName))
                    sites.set(row.siteName, []);
                sites.get(row.siteName).push(row);
            }
            rows.length = 0;
            for (const group of sites.values())
                rows.push(...group);
        }
        var lastSite = "";
        for (var k = 0; k < rows.length; k++) {
            var site = rows[k].siteName;
            var gCount = groupBySite ? sites.get(site).length : 0;
            var showHdr = groupBySite && gCount > 1 && site !== lastSite;
            lastSite = site;

            rows[k].showHeader = showHdr;
            rows[k].groupCount = gCount;
            rows[k].endsGroup = gCount > 1 && (k + 1 === rows.length || rows[k + 1].siteName !== site);
        }
        reconcileRulesModel(rows);
        if (selectingRules) {
            const shown = new Set(rows.map(row => row.uid));
            const selected = {};
            for (const uid of Object.keys(selectedRules)) {
                if (shown.has(Number(uid))) selected[uid] = true;
            }
            selectedRules = selected;
        }
    }

    // Diff-update visibleRulesModel by uid so active delegates keep focus & state.
    function reconcileRulesModel(desired) {
        var wantedUids = {
        };
        for (var i = 0; i < desired.length; i++) wantedUids[desired[i].uid] = true
        for (var r = visibleRulesModel.count - 1; r >= 0; r--) {
            if (!wantedUids[visibleRulesModel.get(r).uid])
                visibleRulesModel.remove(r);

        }
        for (var pos = 0; pos < desired.length; pos++) {
            var item = desired[pos];
            var found = -1;
            for (var scan = pos; scan < visibleRulesModel.count; scan++) {
                if (visibleRulesModel.get(scan).uid === item.uid) {
                    found = scan;
                    break;
                }
            }
            if (found === -1) {
                visibleRulesModel.insert(pos, item);
            } else {
                if (found !== pos)
                    visibleRulesModel.move(found, pos, 1);

                var cur = visibleRulesModel.get(pos);
                if (cur.actualIndex !== item.actualIndex)
                    visibleRulesModel.setProperty(pos, "actualIndex", item.actualIndex);

                if (cur.enabled !== item.enabled)
                    visibleRulesModel.setProperty(pos, "enabled", item.enabled);

                if (cur.pattern !== item.pattern)
                    visibleRulesModel.setProperty(pos, "pattern", item.pattern);

                if (cur.label !== item.label)
                    visibleRulesModel.setProperty(pos, "label", item.label);

                if (cur.isPrivate !== item.isPrivate)
                    visibleRulesModel.setProperty(pos, "isPrivate", item.isPrivate);

                if (cur.siteName !== item.siteName)
                    visibleRulesModel.setProperty(pos, "siteName", item.siteName);

                if (cur.showHeader !== item.showHeader)
                    visibleRulesModel.setProperty(pos, "showHeader", item.showHeader);

                if (cur.groupCount !== item.groupCount)
                    visibleRulesModel.setProperty(pos, "groupCount", item.groupCount);

                if (cur.endsGroup !== item.endsGroup)
                    visibleRulesModel.setProperty(pos, "endsGroup", item.endsGroup);

            }
        }
    }

    function rebuildSuggestions() {
        var activePatterns = Object.create(null);
        for (var i = 0; i < draftRules.length; i++) {
            if (draftRules[i].enabled) {
                var p = String(draftRules[i].pattern || "").trim();
                if (p !== "")
                    activePatterns[p] = true;

            }
        }
        var desired = [];
        for (var s = 0; s < rawSuggestions.length; s++) {
            var raw = rawSuggestions[s];
            if (!raw || typeof raw !== "object")
                continue;

            var origPattern = String(raw.pattern || "").trim();
            var origLabel = String(raw.label || "").trim();
            var origPrivate = !!raw["private"];
            var key = suggestionKeyFor(raw, s);
            if (_stagedSuggestionKeys[key])
                continue;

            if (origPattern !== "" && activePatterns[origPattern])
                continue;

            var edit = _suggestionEdits[key];
            var effPattern = edit && edit.pattern !== undefined ? edit.pattern : origPattern;
            var effLabel = edit && edit.label !== undefined ? edit.label : (origLabel !== "" ? origLabel : (allTargets.length > 0 ? allTargets[0] : ""));
            var effPrivate = edit && edit.isPrivate !== undefined ? edit.isPrivate : origPrivate;
            var title = raw.title !== undefined && raw.title !== null && String(raw.title).trim() !== "" ? String(raw.title).trim() : (origPattern !== "" ? origPattern : "Suggested rule");
            var reason = raw.reason !== undefined && raw.reason !== null ? String(raw.reason).trim() : "";
            desired.push({
                "suggestionKey": key,
                "title": effPattern === origPattern ? title : (effPattern || "Empty pattern"),
                "reason": reason,
                "pattern": effPattern,
                "label": effLabel,
                "isPrivate": effPrivate,
                "kind": suggestionTargetKind(effLabel),
                "uses": Number(raw.uses) || 0,
                "lastUsed": Number(raw.last_used) || 0
            });
        }
        actionableSuggestionCount = desired.length;
        if (!desired.length) {
            suggestionSearch = "";
            suggestionSearchField.text = "";
            suggestionKind = "all";
        }
        const query = suggestionSearch.trim().toLowerCase();
        const shown = desired.filter(item =>
            (suggestionKind === "all" || item.kind === suggestionKind)
            && (!query || [item.title, item.pattern, item.label, item.reason]
                .some(value => value.toLowerCase().includes(query))));
        if (suggestionSort === "used")
            shown.sort((a, b) => b.uses - a.uses || b.lastUsed - a.lastUsed);
        else if (suggestionSort === "recent")
            shown.sort((a, b) => b.lastUsed - a.lastUsed || b.uses - a.uses);
        reconcileSuggestionsModel(shown);
        if (editingSuggestionKey && !shown.some(item => item.suggestionKey === editingSuggestionKey))
            editingSuggestionKey = "";

    }

    function reconcileSuggestionsModel(desired) {
        var wanted = {
        };
        for (var i = 0; i < desired.length; i++) wanted[desired[i].suggestionKey] = true
        for (var r = suggestionsModel.count - 1; r >= 0; r--) {
            if (!wanted[suggestionsModel.get(r).suggestionKey])
                suggestionsModel.remove(r);

        }
        for (var pos = 0; pos < desired.length; pos++) {
            var item = desired[pos];
            var found = -1;
            for (var scan = pos; scan < suggestionsModel.count; scan++) {
                if (suggestionsModel.get(scan).suggestionKey === item.suggestionKey) {
                    found = scan;
                    break;
                }
            }
            if (found === -1) {
                suggestionsModel.insert(pos, item);
            } else {
                if (found !== pos)
                    suggestionsModel.move(found, pos, 1);

                var cur = suggestionsModel.get(pos);
                if (cur.title !== item.title)
                    suggestionsModel.setProperty(pos, "title", item.title);

                if (cur.reason !== item.reason)
                    suggestionsModel.setProperty(pos, "reason", item.reason);

                if (cur.pattern !== item.pattern)
                    suggestionsModel.setProperty(pos, "pattern", item.pattern);

                if (cur.label !== item.label)
                    suggestionsModel.setProperty(pos, "label", item.label);

                if (cur.isPrivate !== item.isPrivate)
                    suggestionsModel.setProperty(pos, "isPrivate", item.isPrivate);

            }
        }
    }

    function _insertNewRule(pattern, label, selectAll) {
        const site = ruleSite(pattern);
        if (!expandedSites[site])
            toggleSite(site);
        var chosenLabel = label !== "" ? label : (allTargets.length > 0 ? allTargets[0] : "");
        var rule = {
            "uid": _nextUid++,
            "enabled": true,
            "pattern": pattern,
            "label": chosenLabel,
            "isPrivate": false
        };
        var next = draftRules.slice();
        if (pattern.trim() !== "") {
            next.unshift(rule);
        } else {
            var insertAt = next.length;
            for (var i = 0; i < next.length; i++) {
                if (String(next[i].pattern || "").trim() === "*") {
                    insertAt = i;
                    break;
                }
            }
            next.splice(insertAt, 0, rule);
        }
        draftRules = next;
        activeTab = "rules";
        selectingRules = false;
        selectedRules = {};
        searchQuery = "";
        filterMode = "all";
        if (searchField && searchField.text !== "")
            searchField.text = "";

        recomputeDirty();
        rebuildVisibleRules();
        rebuildSuggestions();
        _pendingFocusUid = rule.uid;
        _pendingSelectAll = !!selectAll;
        Qt.callLater(function() {
            scrollToRuleUid(rule.uid);
            focusSyncRequested();
        });
    }

    function addBlankRule() {
        _insertNewRule("", "", false);
    }

    function scrollToRuleUid(uid) {
        if (!rulesList)
            return ;

        for (var i = 0; i < visibleRulesModel.count; i++) {
            if (visibleRulesModel.get(i).uid === uid) {
                rulesList.positionViewAtIndex(i, ListView.Contain);
                return ;
            }
        }
    }

    function setRuleEnabled(uid, enabled) {
        var idx = findRuleIndexByUid(uid);
        if (idx < 0)
            return ;

        var next = draftRules.slice();
        next[idx] = Object.assign({
        }, next[idx], {
            "enabled": !!enabled
        });
        draftRules = next;
        recomputeDirty();
        rebuildVisibleRules();
        rebuildSuggestions();
    }

    function setRulePattern(uid, pattern) {
        if (statusIsWarning) { statusMessage = ""; statusIsWarning = false; }
        var idx = findRuleIndexByUid(uid);
        if (idx < 0)
            return ;

        var next = draftRules.slice();
        next[idx] = Object.assign({
        }, next[idx], {
            "pattern": String(pattern)
        });
        draftRules = next;
        recomputeDirty();
        // Keep visibleRulesModel stable while typing so the inline TextField never loses focus.
        for (var i = 0; i < visibleRulesModel.count; i++) {
            if (visibleRulesModel.get(i).uid === uid) {
                visibleRulesModel.setProperty(i, "pattern", String(pattern));
                break;
            }
        }
    }

    function commitRulePatternEdit(uid) {
        if (editingPatternUid === uid)
            editingPatternUid = -1;
        const idx = findRuleIndexByUid(uid);
        if (idx >= 0 && !expandedSites[ruleSite(draftRules[idx].pattern)])
            toggleSite(ruleSite(draftRules[idx].pattern));
        rebuildVisibleRules();
        rebuildSuggestions();
        Qt.callLater(() => scrollToRuleUid(uid));
        scheduleAutosave();
    }

    function setRuleLabel(uid, label) {
        var idx = findRuleIndexByUid(uid);
        if (idx < 0)
            return ;

        if (draftRules[idx].isPrivate && isAppTarget(label)) {
            statusMessage = "Turn off Private before choosing a local app.";
            statusIsWarning = true;
            return;
        }
        var next = draftRules.slice();
        next[idx] = Object.assign({
        }, next[idx], {
            "label": String(label || "")
        });
        draftRules = next;
        recomputeDirty();
        rebuildVisibleRules();
    }

    function setRulePrivate(uid, isPrivate) {
        var idx = findRuleIndexByUid(uid);
        if (idx < 0)
            return ;

        var cur = draftRules[idx];
        if (isPrivate && isAppTarget(cur.label))
            return ;

        var next = draftRules.slice();
        next[idx] = Object.assign({
        }, cur, {
            "isPrivate": !!isPrivate
        });
        draftRules = next;
        recomputeDirty();
        rebuildVisibleRules();
    }

    function moveRule(uid, delta) {
        moveRuleTo(uid, findRuleIndexByUid(uid) + delta + 1);
    }

    function moveRuleTo(uid, position) {
        const idx = findRuleIndexByUid(uid);
        const targetIdx = position - 1;
        if (!canReorder || busy || idx < 0 || !Number.isInteger(position)
                || targetIdx < 0 || targetIdx >= draftRules.length || targetIdx === idx)
            return;
        var next = draftRules.slice();
        var moved = next.splice(idx, 1)[0];
        next.splice(targetIdx, 0, moved);
        draftRules = next;
        recomputeDirty();
        rebuildVisibleRules();
        scrollToRuleUid(uid);
    }

    function updateDragTarget() {
        const y = Math.max(1, Math.min(rulesList.height - 1, dragPointerY));
        const contentY = rulesList.contentY + y;
        const index = rulesList.indexAt(Style.space(28), contentY);
        if (index >= 0)
            dragTarget = index;
        else if (contentY >= rulesList.originY + rulesList.contentHeight)
            dragTarget = draftRules.length - 1;
    }

    function finishRankDrag(commit) {
        const uid = dragRuleUid;
        const position = dragTarget + 1;
        dragRuleUid = -1;
        dragTarget = -1;
        if (commit)
            moveRuleTo(uid, position);
        scheduleAutosave();
    }

    Timer {
        interval: 24
        repeat: true
        running: root.dragRuleUid >= 0 && (root.dragPointerY < Style.space(30)
            || root.dragPointerY > rulesList.height - Style.space(30))
        onTriggered: {
            const delta = root.dragPointerY < Style.space(30) ? -Style.space(10) : Style.space(10);
            const top = rulesList.originY;
            const bottom = top + Math.max(0, rulesList.contentHeight - rulesList.height);
            rulesList.contentY = Math.max(top, Math.min(bottom, rulesList.contentY + delta));
            root.updateDragTarget();
        }
    }

    function selectedRuleUids() {
        return draftRules.filter(rule => selectedRules[rule.uid]).map(rule => rule.uid);
    }

    function requestRemoval(uids, skipConfirmation) {
        if (busy || pendingRemoval.length || !uids.length)
            return;
        if (skipConfirmation || (uids.length === 1 && draftRules.some(rule => rule.uid === uids[0] && !rule.pattern.trim()))) {
            removeRules(uids);
            return;
        }
        pendingRemoval = uids.slice();
        confirmRemove.selectedIndex = 0;
        removalOverlay.forceActiveFocus();
    }

    function finishRemoval(confirmed) {
        const uids = pendingRemoval;
        pendingRemoval = [];
        if (confirmed)
            removeRules(uids);
        else
            scheduleAutosave();
        focusEditor();
    }

    function removeRules(uids) {
        if (busy)
            return;
        removalUndo = draftRules.map((rule, index) => ({rule: Object.assign({}, rule), index: index}))
            .filter(entry => uids.includes(entry.rule.uid));
        draftRules = draftRules.filter(rule => !uids.includes(rule.uid));
        if (uids.includes(editingPatternUid))
            editingPatternUid = -1;
        selectedRules = {};
        selectingRules = false;
        recomputeDirty();
        rebuildVisibleRules();
        rebuildSuggestions();
    }

    function undoRemoval() {
        if (busy || !removalUndo.length)
            return;
        const next = draftRules.slice();
        for (const entry of removalUndo) {
            if (!next.some(rule => rule.uid === entry.rule.uid))
                next.splice(Math.min(entry.index, next.length), 0, entry.rule);
            const site = ruleSite(entry.rule.pattern);
            if (!expandedSites[site]) toggleSite(site);
        }
        removalUndo = [];
        draftRules = next;
        recomputeDirty();
        rebuildVisibleRules();
        rebuildSuggestions();
    }

    function removalMessage() {
        const rules = draftRules.filter(rule => pendingRemoval.includes(rule.uid));
        const names = rules.slice(0, 3).map(rule => rule.pattern + " → " + rule.label);
        return "Remove " + rules.length + (rules.length === 1 ? " rule?" : " rules?")
            + "\n" + names.join("\n") + (rules.length > 3 ? "\n+" + (rules.length - 3) + " more" : "");
    }

    function jumpToPriorityOrder(uid) {
        groupBySite = false;
        filterMode = "all";
        searchQuery = "";
        searchField.text = "";
        chooseSort("priority");
        rebuildVisibleRules();
        Qt.callLater(function() {
            scrollToRuleUid(uid);
        });
    }

    function setFallback(value) {
        statusMessage = "";
        statusIsWarning = false;
        statusShowRulesLink = false;
        draftFallback = String(value || "").trim();
        recomputeDirty();
    }

    function discardChanges() {
        if (busy)
            return ;

        removalUndo = [];
        suggestionUndo = null;
        pendingSuggestionKey = "";
        suggestionPatternRevision++;
        _manualSavePending = false;
        draftRules = cloneRuleList(_baselineRules);
        editingSuggestionKey = "";
        editingPatternUid = -1;
        selectedRules = {};
        selectingRules = false;
        draftFallback = _baselineFallback;
        _stagedSuggestionKeys = ({
        });
        _suggestionEdits = ({
        });
        draftSynced();
        recomputeDirty();
        rebuildVisibleRules();
        rebuildSuggestions();
        statusMessage = "Reverted unsaved changes.";
        draftDiscarded();
        statusIsWarning = false;
        statusShowRulesLink = false;
    }

    function finishRegexValidation() {
        if (pendingSuggestionKey) {
            const key = pendingSuggestionKey;
            pendingSuggestionKey = "";
            stageSuggestion(key);
        }
        if (_manualSavePending) {
            _manualSavePending = false;
            statusMessage = "";
            requestSave(false);
        } else {
            scheduleAutosave();
        }
    }

    function ruleSaveError(rule) {
        if (!rule.pattern.trim()) return "Enter a pattern before saving.";
        const reason = invalidPatternReason(rule.pattern);
        if (reason) return reason;
        if (!rule.label.trim() || rule.label === noneFoundLabel) return "Choose a target before saving.";
        if (rule.isPrivate && isAppTarget(rule.label)) return "Private rules need a browser target. Turn off Private or choose a browser.";
        return "";
    }

    function requestSave(automatic) {
        if (busy || !dirty)
            return ;

        autosaveDelay.stop();
        if (validatedRegexSignature !== JSON.stringify(regexPatterns)) {
            _manualSavePending = true;
            statusMessage = "Checking regex patterns…";
            statusIsWarning = false;
            regexValidationDelay.restart();
            return;
        }
        const incomplete = draftRules.find(rule => !rule.pattern.trim() || !rule.label.trim()
            || rule.label === noneFoundLabel || invalidPatternReason(rule.pattern)
            || (rule.isPrivate && isAppTarget(rule.label)));
        if (incomplete) {
            statusMessage = ruleSaveError(incomplete);
            statusIsWarning = true;
            selectingRules = false;
            selectedRules = {};
            activeTab = "rules";
            filterMode = "all";
            searchQuery = "";
            searchField.text = "";
            if (!expandedSites[ruleSite(incomplete.pattern)]) toggleSite(ruleSite(incomplete.pattern));
            rebuildVisibleRules();
            _pendingFocusUid = incomplete.uid;
            Qt.callLater(() => { scrollToRuleUid(incomplete.uid); focusSyncRequested(); });
            return;
        }
        var payload = buildSavePayload(draftRules, draftFallback);
        _automaticSave = !!automatic;
        _awaitingSave = true;
        statusMessage = "";
        statusIsWarning = false;
        if (!automatic)
            statusShowRulesLink = false;
        saveRequested(payload.rules, payload.fallback);
    }

    function requestRescan() {
        if (busy || _awaitingSave || dirty) {
            if (dirty) {
                statusMessage = "Save or discard changes before rescanning targets.";
                statusIsWarning = true;
            }
            return;
        }

        _rescanInFlight = true;
        statusMessage = "";
        statusIsWarning = false;
        statusShowRulesLink = false;
        rescanRequested();
        Qt.callLater(function() {
            if (!root.busy)
                root._rescanInFlight = false;

        });
    }

    function _ensureSuggestionEdit(key) {
        if (!_suggestionEdits[key]) {
            for (var i = 0; i < suggestionsModel.count; i++) {
                var row = suggestionsModel.get(i);
                if (row.suggestionKey === key) {
                    _suggestionEdits[key] = {
                        "pattern": row.pattern,
                        "label": row.label,
                        "isPrivate": row.isPrivate
                    };
                    break;
                }
            }
        }
        return _suggestionEdits[key];
    }

    function setSuggestionPattern(key, pattern) {
        pendingSuggestionKey = "";
        if (statusIsWarning) { statusMessage = ""; statusIsWarning = false; }
        var edit = _ensureSuggestionEdit(key);
        if (!edit)
            return ;

        edit.pattern = String(pattern);
        suggestionPatternRevision++;
        for (var i = 0; i < suggestionsModel.count; i++) {
            if (suggestionsModel.get(i).suggestionKey === key) {
                suggestionsModel.setProperty(i, "pattern", edit.pattern);
                break;
            }
        }
    }

    function setSuggestionLabel(key, label) {
        pendingSuggestionKey = "";
        if (statusIsWarning) { statusMessage = ""; statusIsWarning = false; }
        var edit = _ensureSuggestionEdit(key);
        if (!edit)
            return ;

        edit.label = String(label || "");
        for (var i = 0; i < suggestionsModel.count; i++) {
            if (suggestionsModel.get(i).suggestionKey === key) {
                suggestionsModel.setProperty(i, "label", edit.label);
                break;
            }
        }
    }

    function setSuggestionPrivate(key, isPrivate) {
        pendingSuggestionKey = "";
        if (statusIsWarning) { statusMessage = ""; statusIsWarning = false; }
        var edit = _ensureSuggestionEdit(key);
        if (!edit)
            return ;

        if (isPrivate && isAppTarget(edit.label))
            return ;

        edit.isPrivate = !!isPrivate;
        for (var i = 0; i < suggestionsModel.count; i++) {
            if (suggestionsModel.get(i).suggestionKey === key) {
                suggestionsModel.setProperty(i, "isPrivate", edit.isPrivate);
                break;
            }
        }
    }

    function suggestionTargetKind(label) {
        const source = rawSuggestions.find(item => item.label === label && item.kind);
        return source ? source.kind : (isAppTarget(label) ? "desktop" : "browser");
    }

    function suggestionError(pattern, label, isPrivate) {
        if (!String(pattern).trim()) return "Enter a link pattern.";
        const error = invalidPatternReason(pattern);
        if (error) return error;
        if (String(pattern).trim().startsWith("regex:")
                && validatedRegexSignature !== JSON.stringify(regexPatterns)) return "Checking regex pattern…";
        if (!label || label === noneFoundLabel) return "Choose a target.";
        if (isMissingTarget(label)) return "Target '" + label + "' not found. Choose another target or Rescan.";
        if (isPrivate && isAppTarget(label)) return "Local apps cannot open private windows. Turn off Private or choose a browser.";
        if (draftRules.some(rule => rule.enabled && rule.pattern.trim() === String(pattern).trim()))
            return "An enabled rule already uses this pattern. Review it in Rules.";
        return "";
    }

    function focusSuggestion(index) {
        if (!suggestionsModel.count) {
            if (suggestionUndo) suggestionUndoButton.forceActiveFocus(); else tabSwitcher.forceActiveFocus();
            return;
        }
        const next = Math.max(0, Math.min(index, suggestionsModel.count - 1));
        suggestionsList.positionViewAtIndex(next, ListView.Contain);
        Qt.callLater(() => {
            const item = suggestionsList.itemAtIndex(next);
            if (item) item.focusEdit(); else suggestionSearchField.forceActiveFocus();
        });
    }

    function stageSuggestion(key) {
        var foundRow = null;
        for (var i = 0; i < suggestionsModel.count; i++) {
            var candidate = suggestionsModel.get(i);
            if (candidate.suggestionKey === key) {
                foundRow = candidate;
                break;
            }
        }
        if (!foundRow)
            return ;

        if (foundRow.pattern.trim().startsWith("regex:")
                && validatedRegexSignature !== JSON.stringify(regexPatterns)) {
            pendingSuggestionKey = key;
            regexValidationDelay.restart();
            return;
        }
        const index = i;
        if (addSuggestionRules([{
            pattern: foundRow.pattern, label: foundRow.label, private: foundRow.isPrivate
        }], key)) focusSuggestion(index);
    }

    function addSuggestionRules(candidates, suggestionKey) {
        if (busy || _awaitingSave) return false;
        const before = cloneRuleList(draftRules);
        const next = draftRules.slice();
        for (const candidate of candidates) {
            const pattern = String(candidate.pattern || "").trim();
            const label = String(candidate.label || "").trim();
            const isPrivate = !!candidate["private"];
            const error = suggestionError(pattern, label, isPrivate);
            if (error) {
                statusMessage = error;
                statusIsWarning = true;
                statusShowRulesLink = false;
                return false;
            }

            const existing = next.findIndex(rule => rule.pattern.trim() === pattern
                && rule.label === label && rule.isPrivate === isPrivate);
            if (existing >= 0) {
                next[existing] = Object.assign({}, next[existing], { enabled: true });
            } else {
                const fallback = next.findIndex(rule => rule.pattern.trim() === "*");
                next.splice(fallback < 0 ? next.length : fallback, 0, {
                    uid: _nextUid++, enabled: true, pattern, label, isPrivate
                });
            }
        }
        const changed = next.filter(rule => !before.some(old => old.uid === rule.uid && old.enabled === rule.enabled));
        if (suggestionKey) suggestionUndo = { key: suggestionKey, changed: changed, before: before };
        lastAddedUid = changed.length ? changed[changed.length - 1].uid : -1;
        draftRules = next;
        if (suggestionKey)
            _stagedSuggestionKeys[suggestionKey] = true;
        recomputeDirty();
        rebuildVisibleRules();
        rebuildSuggestions();
        editingSuggestionKey = "";
        statusMessage = "Added " + candidates.map(item => item.pattern + " → " + item.label).join(", ")
            + (autosave && allowAutosave ? ". Saving automatically." : ". Save changes to apply.");
        statusIsWarning = false;
        statusShowRulesLink = true;
        return true;
    }

    implicitWidth: Style.space(598)
    implicitHeight: Style.space(540)
    onDocumentChanged: applyDocument(document)
    onBusyChanged: {
        // Resume only a scheduled edit interrupted by another operation.
        // A save request stops its timer first, so failed saves are not retried.
        if (busy && autosaveDelay.running && !_awaitingSave) {
            _deferredAutosave = true;
            autosaveDelay.stop();
        }
        if (!busy) {
            Qt.callLater(function() {
                if (!root.busy) {
                    root._rescanInFlight = false;
                    root._awaitingSave = false;
                    root._automaticSave = false;
                    if (root._deferredAutosave) {
                        root._deferredAutosave = false;
                        root.scheduleAutosave();
                    }
                }
            });
        }
    }
    onSortModeChanged: {
        if (sortDropdown && sortDropdown.value !== sortMode)
            sortDropdown.value = sortMode;

    }
    onFilterModeChanged: {
        if (selectingRules) selectedRules = {};
        if (filterDropdown && filterDropdown.value !== filterMode)
            filterDropdown.value = filterMode;

    }
    Component.onCompleted: {
        if (document)
            applyDocument(document);
        else
            _baselineSignature = payloadSignature([], "");
    }
    Keys.onPressed: function(event) {
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
            if (dirty && !busy)
                requestSave();

            event.accepted = true;
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
            addBlankRule();
            event.accepted = true;
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
            if (activeTab === "settings")
                activeTab = "rules";
            const field = activeTab === "suggestions" ? suggestionSearchField : searchField;
            Qt.callLater(function() {
                if (field) {
                    field.forceActiveFocus();
                    field.selectAll();
                }
            });
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape && selectingRules) {
            selectingRules = false;
            selectedRules = {};
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape && activeTab === "suggestions" && editingSuggestionKey) {
            closeSuggestionEditor();
            event.accepted = true;
        }
    }

    function closeSuggestionEditor() {
        pendingSuggestionKey = "";
        let index = 0;
        for (let i = 0; i < suggestionsModel.count; i++)
            if (suggestionsModel.get(i).suggestionKey === editingSuggestionKey) index = i;
        editingSuggestionKey = "";
        rebuildSuggestions();
        focusSuggestion(index);
    }

    function clearSuggestionFilters() {
        suggestionSearch = "";
        suggestionSearchField.text = "";
        suggestionKind = "all";
        rebuildSuggestions();
        suggestionSearchField.forceActiveFocus();
    }

    function undoSuggestion() {
        if (!suggestionUndo || busy || _awaitingSave) return;
        const undo = suggestionUndo;
        const next = draftRules.slice();
        let reverted = 0;
        for (const changed of undo.changed) {
            const index = next.findIndex(rule => rule.uid === changed.uid);
            if (index < 0) continue;
            const current = next[index];
            if (current.pattern !== changed.pattern || current.label !== changed.label
                    || current.isPrivate !== changed.isPrivate || current.enabled !== changed.enabled) continue;
            const old = undo.before.find(rule => rule.uid === changed.uid);
            if (old) next[index] = old; else next.splice(index, 1);
            reverted++;
        }
        if (reverted) delete _stagedSuggestionKeys[undo.key];
        suggestionUndo = null;
        draftRules = next;
        recomputeDirty(); rebuildVisibleRules(); rebuildSuggestions();
        statusMessage = reverted ? "Undid added suggestion." : "Kept the added rule because it was edited. Nothing undone.";
        statusIsWarning = false;
        statusShowRulesLink = false;
    }

    ListModel {
        id: visibleRulesModel
    }

    ListModel {
        id: suggestionsModel
    }

    Timer {
        id: savedIndicator
        interval: 1600
    }

    Rectangle {
        anchors.fill: parent
        color: root.background
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.contentPadding
        spacing: Style.spacing.lg

        // 1. Header bar: section tabs + global actions (revert, rescan, add, save)
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            ButtonGroup {
                id: tabSwitcher

                value: root.activeTab
                foreground: root.foreground
                background: "transparent"
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                options: [{
                    "value": "rules",
                    "label": "Rules (" + root.draftRules.length + ")",
                    "tooltip": "Choose where matching links open"
                }, {
                    "value": "suggestions",
                    "label": root.actionableSuggestionCount > 0 ? ("Suggestions (" + root.actionableSuggestionCount + ")") : "Suggestions",
                    "tooltip": "Make rules from detected apps and repeated choices"
                }, {
                    "value": "settings",
                    "label": "Settings",
                    "tooltip": "Set up saving, unmatched links, and app shortcuts"
                }]
                onChanged: function(nextTab) {
                    root.activeTab = nextTab;
                    if (nextTab === "rules") root.statusShowRulesLink = false;
                    if (nextTab !== "suggestions") root.editingSuggestionKey = "";
                    if (nextTab === "suggestions")
                        root.rebuildSuggestions();

                }
            }

            Item {
                Layout.fillWidth: true
            }

            Button {
                visible: root.statusShowRulesLink && root.activeTab !== "rules"
                text: "View rules"
                tooltipText: "Open the Rules tab"
                focusable: true
                fontSize: Style.font.bodySmall
                onClicked: {
                    root.activeTab = "rules";
                    root.searchQuery = ""; searchField.text = ""; root.filterMode = "all";
                    const rule = root.draftRules.find(item => item.uid === root.lastAddedUid);
                    if (rule && !root.expandedSites[root.ruleSite(rule.pattern)]) root.toggleSite(root.ruleSite(rule.pattern));
                    root.rebuildVisibleRules();
                    Qt.callLater(() => root.scrollToRuleUid(root.lastAddedUid));
                    root.statusShowRulesLink = false;
                }
            }

            Text {
                visible: savedIndicator.running && !root.dirty
                text: "Saved"
                textFormat: Text.PlainText
                color: Util.alpha(root.foreground, 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }


            Button {
                visible: root.activeTab === "rules" && root.draftRules.length > 0 && !root.tracingUrl
                text: root.selectingRules ? "Done" : "Select"
                fontSize: Style.font.bodySmall
                tooltipText: root.selectingRules ? "Exit selection mode and clear the selection" : "Edit or remove several rules together. Ctrl- or Shift-click also selects rows."
                bordered: true
                focusable: true
                onClicked: {
                    root.selectingRules = !root.selectingRules;
                    root.selectedRules = {};
                }
            }

            Button {
                visible: root.activeTab === "rules" && !root.selectingRules
                iconText: "󰐕"
                text: "Add"
                tooltipText: "Add a new rule (Ctrl+N)"
                bordered: true
                focusable: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                iconSize: Style.font.iconSmall
                horizontalPadding: Style.spacing.lg
                onClicked: root.addBlankRule()
            }



        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.activeTab === "rules" && root._hasLoadedDocument && !root.onboardingSeen
            spacing: Style.spacing.md
            Text {
                Layout.fillWidth: true
                text: "Set up link handling, web app profiles, and suggested rules?"
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
            Button {
                text: "Start setup"
                tooltipText: "Review web app profiles, app rules, and system integration"
                bordered: true
                focusable: true
                enabled: !root.busy
                onClicked: root.startRecommendedSetup()
            }
            Button {
                text: "Skip"
                tooltipText: "Skip for now. Run recommended setup anytime in Settings."
                focusable: true
                onClicked: root.dismissOnboarding()
            }
        }

        // 2. Rules search / sort / filter toolbar
        RowLayout {
            Layout.fillWidth: true
            visible: root.activeTab === "rules" && root.selectingRules && !root.tracingUrl
            Layout.preferredHeight: searchField.implicitHeight
            spacing: Style.spacing.sm

            Text {
                visible: root.selectingRules
                text: root.selectedRuleCount + " selected"
                textFormat: Text.PlainText
                color: Util.alpha(root.foreground, 0.85)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
            Button {
                text: "Select all"
                tooltipText: "Select or clear all filtered rules, including collapsed groups"
                focusable: true
                onClicked: {
                    const uids = [];
                    for (let i = 0; i < visibleRulesModel.count; i++)
                        uids.push(visibleRulesModel.get(i).uid);
                    root.toggleSelection(uids);
                }
            }
            Item { Layout.fillWidth: true }
            TargetPicker {
                visible: root.selectedRuleCount > 0 && root.selectingRules
                enabled: !root.busy
                placeholderText: "Set target"
                tooltipText: "Change where all selected rules open links"
                options: root.ruleTargetOptions("")
                onPicked: value => root.applyBulk("target", value)
            }
            TargetPicker {
                visible: root.selectedRuleCount > 0
                enabled: !root.busy
                Layout.preferredWidth: Style.space(110)
                placeholderText: "Actions"
                tooltipText: "Enable, disable, or change privacy for selected rules"
                options: [
                    { value: "enable", label: "Enable" },
                    { value: "disable", label: "Disable" },
                    { value: "private", label: "Make private" },
                    { value: "normal", label: "Make normal" }
                ]
                onPicked: value => {
                    const privacy = value === "private" || value === "normal";
                    root.applyBulk(privacy ? "private" : "enable", value === "private" || value === "enable");
                }
            }
            Button {
                visible: root.selectedRuleCount > 0
                text: "Remove"
                foreground: root.urgent
                focusable: true
                enabled: !root.busy
                tooltipText: "Remove selected rules · Shift-click to skip confirmation"
                onClicked: root.requestRemoval(root.selectedRuleUids(), false)
                ShiftRemoveClick {
                    enabled: !root.busy
                    onShiftClicked: root.requestRemoval(root.selectedRuleUids(), true)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.activeTab === "rules"
            Layout.preferredHeight: searchField.implicitHeight
            spacing: Style.spacing.md

            Item {
                Layout.fillWidth: true
                Layout.minimumWidth: Style.space(92)
                implicitHeight: searchField.implicitHeight

                TextField {
                    id: searchField

                    anchors.fill: parent
                    placeholderText: "Search rules or paste a link to test…"
                    text: root.searchQuery
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    horizontalPadding: Style.spacing.lg
                    verticalPadding: Style.spacing.sm
                    rightPadding: clearSearchBtn.visible ? Style.space(26) : Style.spacing.lg
                    onTextChanged: {
                        if (root.searchQuery !== text) {
                            root.searchQuery = text;
                            root.rebuildVisibleRules();
                        }
                    }
                    Keys.onEscapePressed: {
                        if (text !== "")
                            text = "";

                    }
                }

                PanelActionButton {
                    id: clearSearchBtn

                    visible: searchField.text !== ""
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.xs
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "\u00d7"
                    tooltipText: "Clear search"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    size: Style.space(20)
                    onClicked: {
                        searchField.text = "";
                        searchField.forceActiveFocus();
                    }
                }

            }

        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.activeTab === "rules" && root.draftRules.length > 0 && !root.selectingRules && !root.tracingUrl
            spacing: Style.spacing.md

            Item {
                id: groupControl
                visible: !root.tracingUrl
                implicitWidth: groupContents.implicitWidth + Style.space(8)
                implicitHeight: searchField.implicitHeight
                activeFocusOnTab: true
                Accessible.role: Accessible.CheckBox
                Accessible.name: "Group by site"
                Accessible.checkable: true
                Accessible.checked: root.groupBySite
                Accessible.onPressAction: toggle()
                Keys.onSpacePressed: toggle()
                Keys.onReturnPressed: toggle()

                function toggle() {
                    root.groupBySite = !root.groupBySite;
                    root.rebuildVisibleRules();
                }

                BorderSurface {
                    anchors.fill: parent
                    visible: groupControl.activeFocus
                    borderSpec: Border.controlSpec("focus", root.foreground, root.accent)
                    color: "transparent"
                }

                Row {
                    id: groupContents
                    anchors.centerIn: parent
                    spacing: Style.spacing.xs
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Group"
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                    ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: root.groupBySite
                        interactive: false
                        trackHeight: Style.space(14)
                        foreground: root.foreground
                        accent: root.accent
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onClicked: groupControl.toggle()
                    id: groupMouse
                }
                PanelToolTip {
                    visible: groupMouse.containsMouse
                    text: "Group by site"
                }
            }

            HelpDropdown {
                id: sortDropdown
                tooltipText: "Change display order without changing which rule matches first"
                visible: !root.tracingUrl

                showLabel: false
                Layout.preferredWidth: Style.space(root.groupBySite ? 150 : 104)
                rowHeight: searchField.implicitHeight
                value: root.sortMode
                foreground: root.foreground
                background: root.popupBackground
                popupBorder: root.popupBorder
                accent: root.accent
                fontFamily: root.fontFamily
                options: [{
                    "value": "site",
                    "label": "Site A–Z"
                }, {
                    "value": "priority",
                    "label": root.groupBySite ? "Site priority" : "Priority"
                }, {
                    "value": "pattern",
                    "label": "Pattern"
                }, {
                    "value": "target",
                    "label": "Target"
                }]
                onChanged: function(val) {
                    root.chooseSort(val);
                }
            }

            HelpDropdown {
                id: filterDropdown
                tooltipText: "Filter by whether rules are enabled, private, or conflicting"
                visible: !root.tracingUrl

                showLabel: false
                Layout.preferredWidth: Style.space(104)
                rowHeight: searchField.implicitHeight
                value: root.filterMode
                foreground: root.foreground
                background: root.popupBackground
                popupBorder: root.popupBorder
                accent: root.accent
                fontFamily: root.fontFamily
                options: [{
                    "value": "all",
                    "label": "All rules"
                }, {
                    "value": "enabled",
                    "label": "Enabled"
                }, {
                    "value": "disabled",
                    "label": "Disabled"
                }, {
                    "value": "private",
                    "label": "Private"
                }, {
                    "value": "conflicts",
                    "label": "Conflicts (" + root.ruleConflictCount + ")"
                }]
                onChanged: function(val) {
                    root.filterMode = val;
                    root.rebuildVisibleRules();
                }
            }

            Button {
                visible: !root.tracingUrl && !root.canReorder
                text: "Reorder"
                tooltipText: "Ungroup rules and clear filters so you can change match order"
                focusable: true
                onClicked: {
                    root.groupBySite = false;
                    root.filterMode = "all";
                    searchField.text = "";
                    root.chooseSort("priority");
                    root.rebuildVisibleRules();
                }
            }

            Item {
                visible: !root.tracingUrl && (root.searchQuery.trim() !== "" || root.filterMode !== "all")
                implicitWidth: countLabel.implicitWidth + Style.spacing.xs * 2
                implicitHeight: searchField.implicitHeight

                Text {
                    id: countLabel

                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: visibleRulesModel.count + "/" + root.draftRules.length
                    color: Util.alpha(root.foreground, 0.6)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }

                MouseArea {
                    id: countMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                }

                PanelToolTip {
                    visible: countMouse.containsMouse
                    text: "Shown / total rules · Lower # matches first"
                    fontFamily: root.fontFamily
                }

            }

        }

        Button {
            visible: root.activeTab === "rules" && !root.tracingUrl
                && root.ruleConflictCount > 0 && root.filterMode !== "conflicts"
            text: root.ruleConflictCount === 1 ? "1 rule conflict" : root.ruleConflictCount + " rule conflicts"
            tooltipText: "Show enabled rules with the same pattern as an earlier rule"
            foreground: root.urgent
            focusable: true
            onClicked: {
                root.filterMode = "conflicts";
                searchField.text = "";
                root.searchQuery = "";
                root.rebuildVisibleRules();
            }
        }

        // Reorder hint banner when in Priority view with active filters
        RowLayout {
            Layout.fillWidth: true
            visible: root.activeTab === "rules" && !root.tracingUrl && !root.groupBySite && root.sortMode === "priority" && !root.canReorder
            spacing: Style.spacing.md

            Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: "Clear search and filters to change match order."
                color: Util.alpha(root.foreground, 0.65)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
            }

            Button {
                text: "Clear filters"
                tooltipText: "Clear search and show all rules"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.xxs
                onClicked: {
                    root.filterMode = "all";
                    root.searchQuery = "";
                    if (searchField)
                        searchField.text = "";

                    root.rebuildVisibleRules();
                }
            }

        }

        ColumnLayout {
            visible: root.activeTab === "suggestions" && root.actionableSuggestionCount > 0
            Layout.fillWidth: true
            spacing: Style.spacing.sm
            Item {
                Layout.fillWidth: true
                implicitHeight: suggestionSearchField.implicitHeight
                TextField {
                    id: suggestionSearchField
                    anchors.fill: parent
                    placeholderText: "Search suggestions…"
                    foreground: root.foreground; accent: root.accent
                    font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                    horizontalPadding: Style.spacing.lg; verticalPadding: Style.spacing.sm
                    rightPadding: suggestionClear.visible ? Style.space(26) : Style.spacing.lg
                    text: root.suggestionSearch
                    onTextChanged: {
                        if (root.suggestionSearch !== text) {
                            root.suggestionSearch = text;
                            root.rebuildSuggestions();
                            suggestionsList.positionViewAtBeginning();
                        }
                    }
                    Keys.onEscapePressed: event => {
                        if (text !== "") text = ""; else event.accepted = false;
                    }
                }
                PanelActionButton {
                    id: suggestionClear
                    visible: suggestionSearchField.text !== ""
                    anchors.right: parent.right; anchors.rightMargin: Style.spacing.xs; anchors.verticalCenter: parent.verticalCenter
                    iconText: "\u00d7"; tooltipText: "Clear search"; size: Style.space(20)
                    foreground: root.foreground
                    onClicked: { suggestionSearchField.text = ""; suggestionSearchField.forceActiveFocus(); }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.sm
            HelpDropdown {
                tooltipText: "Sort suggestions by recommendation, usage, or recency"
                Layout.preferredWidth: Style.space(132)
                showLabel: false
                rowHeight: suggestionSearchField.implicitHeight
                value: root.suggestionSort
                options: [
                    { value: "recommended", label: "Recommended" },
                    { value: "used", label: "Most used" },
                    { value: "recent", label: "Most recent" }
                ]
                onChanged: order => {
                    root.suggestionSort = order;
                    root.rebuildSuggestions();
                    suggestionsList.positionViewAtBeginning();
                }
            }
            HelpDropdown {
                tooltipText: "Filter suggestions by the kind of app or profile they open"
                Layout.preferredWidth: Style.space(132)
                showLabel: false
                rowHeight: suggestionSearchField.implicitHeight
                value: root.suggestionKind
                options: [
                    { value: "all", label: "All targets" },
                    { value: "webapp", label: "Web apps" },
                    { value: "desktop", label: "Desktop apps" },
                    { value: "browser", label: "Browser profiles" }
                ]
                onChanged: kind => {
                    root.suggestionKind = kind;
                    root.rebuildSuggestions();
                    suggestionsList.positionViewAtBeginning();
                }
            }
                Item { Layout.fillWidth: true }
                Text {
                    text: suggestionsModel.count + " / " + root.actionableSuggestionCount
                    color: Util.alpha(root.foreground, 0.65)
                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }
            }
        }


        PanelSeparator {
            Layout.fillWidth: true
            foreground: root.foreground
        }

        // 3. Main scrollable list (Rules OR Suggestions)
        Item {
            visible: root.activeTab !== "settings"
            enabled: !root._awaitingSave
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.fill: parent
                visible: root.activeTab === "rules" && root.tracingUrl
                spacing: Style.spacing.sm

                Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.traceError || (!root.traceResult ? "Checking URL…"
                        : root.traceResult.outcome === "rule" ? "Matching rules · first usable match opens"
                        : root.traceResult.matches.length ? "The chooser opens · matching rules shown below"
                        : "No rules match. The chooser opens.")
                    color: root.traceError ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                }

                ListView {
                    id: traceList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.traceResult ? root.traceResult.matches : []
                    Controls.ScrollBar.vertical: Controls.ScrollBar {
                        policy: traceList.contentHeight > traceList.height ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
                    }
                    delegate: Column {
                        required property var modelData
                        width: traceList.width - Style.spacing.md
                        spacing: Style.spacing.xxs
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: (modelData.fallback ? "Fallback" : "#" + modelData.priority)
                                + "  " + modelData.pattern
                            color: modelData.status === "winner" ? root.accent : root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: modelData.label + (modelData["private"] ? " · Private" : "")
                                + " · " + root.traceStatus(modelData.status)
                            color: Util.alpha(root.foreground, 0.75)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                        }
                        Item { width: 1; height: Style.spacing.xs }
                        PanelSeparator { width: parent.width; foreground: root.foreground }
                        Item { width: 1; height: Style.spacing.xs }
                    }
                }
            }

            // ---- Rules list view ----
            ListView {
                id: rulesList

                anchors.fill: parent
                visible: root.activeTab === "rules" && !root.tracingUrl
                clip: true
                spacing: 0
                boundsBehavior: Flickable.StopAtBounds
                model: visibleRulesModel

                Controls.ScrollBar.vertical: Controls.ScrollBar {
                    id: rulesScrollBar
                    anchors.right: rulesList.right
                    z: 1
                    policy: rulesList.contentHeight > rulesList.height
                        ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
                    width: Style.space(9)
                    padding: Style.space(2)
                    contentItem: Rectangle {
                        radius: width / 2
                        color: Util.alpha(root.foreground, rulesScrollBar.pressed ? 0.8 : 0.48)
                    }
                }

                delegate: Column {
                    id: rowDelegate

                    required property int index
                    required property int uid
                    required property int actualIndex
                    required property bool enabled
                    required property string pattern
                    required property string label
                    required property bool isPrivate
                    required property string siteName
                    required property bool showHeader
                    required property int groupCount
                    required property bool endsGroup
                    readonly property bool groupOpen: groupCount < 2 || root.searchQuery.trim() !== ""
                        || root.filterMode !== "all" || !!root.expandedSites[siteName]
                    readonly property bool isApp: root.isAppTarget(label)
                    readonly property bool targetMissing: root.isMissingTarget(label)
                    readonly property bool invalidPrivate: isApp && isPrivate
                    readonly property string patternError: root.invalidPatternReason(pattern)
                    readonly property string conflictWarning: root.ruleConflicts[uid] || ""
                    readonly property string warningText: [
                        patternError,
                        invalidPrivate ? "'" + label + "' is a local app. Pick a browser or turn off Private." : "",
                        targetMissing && !invalidPrivate ? "Target '" + label + "' not found. Pick another or rescan." : "",
                        conflictWarning
                    ].filter(message => message !== "").join("\n")
                    readonly property bool hasWarning: warningText !== ""

                    function tryClaimFocus() {
                        if (root._pendingFocusUid === rowDelegate.uid) {
                            var shouldSelect = root._pendingSelectAll;
                            root._pendingFocusUid = -1;
                            root._pendingSelectAll = false;
                            patternField.forceActiveFocus();
                            if (shouldSelect)
                                patternField.selectAll();

                        }
                    }

                    Component.onCompleted: {
                        if (root._pendingFocusUid === uid)
                            tryClaimFocus();
                    }
                    width: rulesList.width - (rulesScrollBar.visible ? rulesScrollBar.width + Style.spacing.xs : 0)
                    spacing: 0

                    Connections {
                        function onFocusSyncRequested() {
                            rowDelegate.tryClaimFocus();
                        }

                        function onDraftSynced() {
                            if (patternField.text !== rowDelegate.pattern)
                                patternField.text = rowDelegate.pattern;

                        }

                        target: root
                    }

                    // Group header — shown ONLY in Site view when a site has 2+ visible rules
                    Item {
                        visible: rowDelegate.showHeader
                        width: parent.width
                        height: visible ? (headerRow.implicitHeight + (rowDelegate.index === 0 ? Style.spacing.xs : Style.spacing.xl)) : 0

                        RowLayout {
                            id: headerRow

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Style.spacing.xxs
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Style.spacing.xxs
                            spacing: Style.spacing.md

                            SelectionCheck {
                                visible: root.selectingRules
                                readonly property var groupUids: root.visibleSiteUids(rowDelegate.siteName)
                                readonly property int selectedCount: groupUids.filter(uid => root.selectedRules[uid]).length
                                checkState: selectedCount === groupUids.length ? Qt.Checked : selectedCount > 0 ? Qt.PartiallyChecked : Qt.Unchecked
                                Accessible.name: "Select group"
                                tooltipText: checked ? "Clear selection for this site" : "Select all filtered rules for this site, including collapsed rules"
                                onClicked: root.toggleSelection(root.visibleSiteUids(rowDelegate.siteName))
                            }

                            Button {
                                Layout.fillWidth: true
                                text: (rowDelegate.groupOpen ? "▾  " : "▸  ") + rowDelegate.siteName
                                tooltipText: rowDelegate.groupOpen ? "Collapse rules for this site" : "Expand rules for this site"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                leftAlign: true
                                focusable: true
                                enabled: root.searchQuery.trim() === "" && root.filterMode === "all"
                                onClicked: root.toggleSite(rowDelegate.siteName)
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: root.selectingRules ? root.visibleSiteUids(rowDelegate.siteName).filter(uid => root.selectedRules[uid]).length + " of " + rowDelegate.groupCount + " selected" : rowDelegate.groupCount + " rules"
                                color: Util.alpha(root.foreground, 0.48)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }



                        }

                    }

                    // Compact inline rule row
                    Rectangle {
                        id: ruleSurface

                        width: parent.width
                        visible: rowDelegate.groupOpen
                        height: visible ? Style.space(34) : 0
                        color: root.selectingRules && root.selectedRules[rowDelegate.uid]
                            ? Util.alpha(root.accent, 0.13)
                            : Util.alpha(root.foreground, rowHover.hovered ? 0.07 : (rowDelegate.groupCount > 1 ? 0.035 : 0))

                        Rectangle {
                            visible: rowDelegate.groupCount > 1
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: Style.space(2)
                            color: Util.alpha(root.accent, 0.62)
                        }

                        MouseArea {
                            id: selectionMouse
                            anchors.fill: parent
                            z: 3
                            onPressed: mouse => {
                                const shiftRemove = (mouse.modifiers & Qt.ShiftModifier)
                                    && !(mouse.modifiers & Qt.ControlModifier) && removeRuleButton.visible
                                    && removeRuleButton.contains(removeRuleButton.mapFromItem(selectionMouse, mouse.x, mouse.y));
                                if (shiftRemove) {
                                    mouse.accepted = false;
                                    return;
                                }
                                const editingPattern = patternField.activeFocus
                                    && patternField.contains(patternField.mapFromItem(selectionMouse, mouse.x, mouse.y));
                                mouse.accepted = !editingPattern && (root.selectingRules
                                    || !!(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)));
                                if (!mouse.accepted)
                                    root.selectionAnchor = rowDelegate.uid;
                            }
                            onClicked: mouse => root.selectWithModifier(rowDelegate.uid, mouse.modifiers)
                        }

                        HoverHandler {
                            id: rowHover
                        }

                        Rectangle {
                            readonly property int sourceIndex: root.findRuleIndexByUid(root.dragRuleUid)
                            visible: root.dragRuleUid >= 0 && root.dragTarget === rowDelegate.actualIndex
                                && sourceIndex !== rowDelegate.actualIndex
                            anchors.left: parent.left
                            anchors.right: parent.right
                            y: sourceIndex > rowDelegate.actualIndex ? 0 : parent.height - height
                            height: Style.space(2)
                            color: root.accent
                            z: 2
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.spacing.xxs
                            anchors.rightMargin: Style.spacing.xxs
                            spacing: Style.spacing.md

                            SelectionCheck {
                                visible: root.selectingRules
                                checked: !!root.selectedRules[rowDelegate.uid]
                                Accessible.name: "Select rule #" + (rowDelegate.actualIndex + 1)
                                tooltipText: checked ? "Deselect this rule" : "Select this rule for bulk changes"
                                onClicked: {
                                    root.selectionAnchor = rowDelegate.uid;
                                    root.toggleSelection([rowDelegate.uid]);
                                }
                            }

                            // Actual priority badge (#1 matches first)
                            Item {
                                id: rank
                                Layout.preferredWidth: Style.space(26)
                                Layout.fillHeight: true
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: "Priority " + (rowDelegate.actualIndex + 1)
                                Accessible.onPressAction: activate()
                                BorderSurface {
                                    anchors.fill: parent
                                    color: "transparent"
                                    borderSpec: rank.activeFocus ? Border.controlSpec("focus", root.foreground, root.accent) : Border.none()
                                }
                                Keys.onReturnPressed: activate()
                                Keys.onSpacePressed: activate()

                                function activate() {
                                    if (!root.canReorder) {
                                        root.jumpToPriorityOrder(rowDelegate.uid);
                                        return;
                                    }
                                    positionField.text = String(rowDelegate.actualIndex + 1);
                                    positionPopup.open();
                                }

                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.PlainText
                                    text: "#" + (rowDelegate.actualIndex + 1)
                                    color: rankMouse.containsMouse ? root.accent : Util.alpha(root.foreground, rowDelegate.enabled ? 0.52 : 0.32)
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                }

                                MouseArea {
                                    id: rankMouse

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    preventStealing: root.canReorder
                                    cursorShape: root.dragRuleUid === rowDelegate.uid
                                        ? Qt.ClosedHandCursor : root.canReorder ? Qt.OpenHandCursor : Qt.PointingHandCursor
                                    property real startY: 0
                                    onPressed: mouse => startY = rankMouse.mapToItem(rulesList, mouse.x, mouse.y).y
                                    onPositionChanged: mouse => {
                                        if (!pressed || !root.canReorder)
                                            return;
                                        const y = rankMouse.mapToItem(rulesList, mouse.x, mouse.y).y;
                                        if (root.dragRuleUid < 0 && Math.abs(y - startY) < Style.space(7))
                                            return;
                                        root.dragRuleUid = rowDelegate.uid;
                                        root.dragPointerY = y;
                                        root.updateDragTarget();
                                    }
                                    onReleased: mouse => {
                                        if (root.dragRuleUid === rowDelegate.uid)
                                            root.finishRankDrag(true);
                                        else if (containsMouse)
                                            rank.activate();
                                    }
                                    onCanceled: if (root.dragRuleUid === rowDelegate.uid) root.finishRankDrag(false)
                                }

                                Controls.Popup {
                                    id: positionPopup
                                    y: rank.height
                                    width: Style.space(160)
                                    padding: Style.spacing.md
                                    focus: true
                                    closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
                                    onOpened: {
                                        positionField.forceActiveFocus();
                                        positionField.selectAll();
                                    }
                                    background: BorderSurface {
                                        color: root.popupBackground
                                        borderSpec: Border.flat(root.accent, 1)
                                    }
                                    contentItem: TextField {
                                        id: positionField
                                        placeholderText: "New position"
                                        Accessible.name: "New rule position"
                                        inputMethodHints: Qt.ImhDigitsOnly
                                        validator: IntValidator { bottom: 1; top: root.draftRules.length }
                                        onAccepted: {
                                            root.moveRuleTo(rowDelegate.uid, Number(text));
                                            positionPopup.close();
                                        }
                                    }
                                }

                                PanelToolTip {
                                    visible: rankMouse.containsMouse
                                    text: root.canReorder ? "Click to enter a position or drag to change match order" : "Ungroup and clear filters to change match order"
                                    fontFamily: root.fontFamily
                                }

                            }

                            // Enable / disable switch
                            Item {
                                Layout.preferredWidth: enableSwitch.implicitWidth
                                Layout.preferredHeight: Style.space(28)
                                activeFocusOnTab: true
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: "Enable rule #" + (rowDelegate.actualIndex + 1)
                                Accessible.checkable: true
                                Accessible.checked: rowDelegate.enabled
                                Accessible.onPressAction: root.setRuleEnabled(rowDelegate.uid, !rowDelegate.enabled)
                                Keys.onSpacePressed: root.setRuleEnabled(rowDelegate.uid, !rowDelegate.enabled)
                                Keys.onReturnPressed: root.setRuleEnabled(rowDelegate.uid, !rowDelegate.enabled)
                                BorderSurface {
                                    anchors.fill: parent
                                    color: "transparent"
                                    borderSpec: parent.activeFocus ? Border.controlSpec("focus", root.foreground, root.accent) : Border.none()
                                }

                                ToggleSwitch {
                                    id: enableSwitch

                                    anchors.centerIn: parent
                                    checked: rowDelegate.enabled
                                    cursorRing: false
                                    trackHeight: Style.space(14)
                                    trackWidth: Style.space(26)
                                    knobSize: Style.space(8)
                                    foreground: root.foreground
                                    accent: root.accent
                                    onToggled: root.setRuleEnabled(rowDelegate.uid, !rowDelegate.enabled)
                                }

                                PanelToolTip {
                                    visible: enableSwitch.containsMouse
                                    text: rowDelegate.enabled ? "Disable rule" : "Enable rule"
                                    fontFamily: root.fontFamily
                                }

                            }

                            // Inline editable pattern
                            TextField {
                                id: patternField

                                property string syncedText: rowDelegate.pattern

                                Layout.fillWidth: true
                                Layout.minimumWidth: Style.space(104)
                                Layout.preferredHeight: Style.space(26)
                                opacity: rowDelegate.enabled ? 1 : 0.56
                                placeholderText: "github.com/org/repo  (or regex:…)"
                                foreground: root.foreground
                                accent: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                horizontalPadding: Style.spacing.md
                                verticalPadding: Style.spacing.xs
                                onSyncedTextChanged: {
                                    if (!activeFocus && text !== syncedText)
                                        text = syncedText;

                                }
                                Component.onCompleted: text = rowDelegate.pattern
                                onTextEdited: {
                                    root.editingPatternUid = rowDelegate.uid;
                                    root.setRulePattern(rowDelegate.uid, text);
                                }
                                onEditingFinished: root.commitRulePatternEdit(rowDelegate.uid)

                                background: BorderSurface {
                                    color: patternField.activeFocus ? Style.focusFillFor(root.foreground, root.accent) : (patternField.hovered ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
                                    borderSpec: patternField.activeFocus ? Border.controlSpec("focus", root.foreground, root.accent) : (patternField.hovered ? Border.controlSpec("hover-cursor", root.foreground, root.accent) : Border.none())
                                    radius: Style.cornerRadius
                                }

                            }

                            // Inline target selector
                            TargetPicker {
                                id: ruleTargetPicker
                                tooltipText: "Choose where this rule opens matching links"

                                Layout.preferredWidth: !root.groupBySite && root.sortMode === "priority" ? Style.space(142) : Style.space(164)
                                Layout.minimumWidth: Style.space(96)
                                opacity: rowDelegate.enabled ? 1 : 0.56
                                subtle: true
                                warning: rowDelegate.targetMissing
                                value: rowDelegate.label
                                options: root.ruleTargetOptions(rowDelegate.label)
                                placeholderText: root.noneFoundLabel
                                onPicked: function(val) {
                                    root.setRuleLabel(rowDelegate.uid, val);
                                }
                            }

                            // Private window toggle
                            PrivateToggleButton {
                                active: rowDelegate.isPrivate
                                invalid: rowDelegate.invalidPrivate
                                enabled: !rowDelegate.isApp || rowDelegate.isPrivate
                                tooltipText: rowDelegate.invalidPrivate ? rowDelegate.warningText : (rowDelegate.isApp ? "Private windows apply to browsers only" : (rowDelegate.isPrivate ? "Private window enabled — click to turn off" : "Open matching links in a private window"))
                                onToggled: root.setRulePrivate(rowDelegate.uid, !rowDelegate.isPrivate)
                            }

                            // Warning indicator (only shown when needed)
                            WarningBadge {
                                visible: rowDelegate.hasWarning
                                tooltipText: rowDelegate.warningText
                            }

                            // Direct priority reorder controls (visible in Priority view)
                            PanelActionButton {
                                visible: !root.groupBySite && root.sortMode === "priority"
                                focusable: true
                                enabled: root.canReorder && rowDelegate.actualIndex > 0
                                iconText: "󰅃"
                                size: Style.space(22)
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                fontSize: Style.font.iconSmall
                                tooltipText: root.canReorder ? "Move up (higher priority)" : "Clear filters to reorder"
                                onClicked: root.moveRule(rowDelegate.uid, -1)
                            }

                            PanelActionButton {
                                visible: !root.groupBySite && root.sortMode === "priority"
                                focusable: true
                                enabled: root.canReorder && rowDelegate.actualIndex < root.draftRules.length - 1
                                iconText: "󰅀"
                                size: Style.space(22)
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                fontSize: Style.font.iconSmall
                                tooltipText: root.canReorder ? "Move down (lower priority)" : "Clear filters to reorder"
                                onClicked: root.moveRule(rowDelegate.uid, 1)
                            }

                            // Delete rule button
                            PanelActionButton {
                                id: removeRuleButton
                                visible: !root.selectingRules
                                enabled: !root.busy
                                focusable: true
                                iconText: "\u00d7"
                                size: Style.space(22)
                                foreground: Util.alpha(root.foreground, 0.72)
                                hoverColor: root.urgent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.body
                                tooltipText: "Remove rule · Shift-click to skip confirmation"
                                onClicked: root.requestRemoval([rowDelegate.uid], false)
                                ShiftRemoveClick {
                                    enabled: !root.busy
                                    onShiftClicked: root.requestRemoval([rowDelegate.uid], true)
                                }
                            }

                        }

                    }

                    PanelSeparator {
                        visible: rowDelegate.groupOpen
                        width: parent.width
                        foreground: root.foreground
                        strength: 0.08
                    }

                    Item {
                        width: parent.width
                        height: rowDelegate.endsGroup && rowDelegate.groupOpen ? Style.space(12) : 0
                    }

                }

            }

            // Empty state for Rules view
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - Style.spacing.huge * 2, Style.space(380))
                visible: root.activeTab === "rules" && !root.tracingUrl && visibleRulesModel.count === 0
                spacing: Style.spacing.lg

                Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.draftRules.length === 0 ? "No rules yet. Route specific sites or paths to a browser profile or local app." : "No rules match the current search or filter."
                    color: Util.alpha(root.foreground, 0.65)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }

                Button {
                    Layout.alignment: Qt.AlignHCenter
                    visible: root.draftRules.length === 0
                    text: "Add rule"
                    bordered: true
                    focusable: true
                    onClicked: root.addBlankRule()
                }

                Button {
                    Layout.alignment: Qt.AlignHCenter
                    visible: root.draftRules.length > 0
                    text: "Clear filters"
                    tooltipText: "Clear search and show all rules"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: {
                        root.filterMode = "all";
                        root.searchQuery = "";
                        if (searchField)
                            searchField.text = "";

                        root.rebuildVisibleRules();
                    }
                }

            }

            // ---- Suggestions list view (inline editable + explicit Stage) ----
            ListView {
                id: suggestionsList

                anchors.fill: parent
                visible: root.activeTab === "suggestions"
                clip: true
                reuseItems: false
                boundsBehavior: Flickable.StopAtBounds
                model: suggestionsModel

                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        if (suggestionsList.contentHeight <= suggestionsList.height)
                            return;
                        const delta = event.pixelDelta.y || event.angleDelta.y / 120 * Style.space(108);
                        if (!delta)
                            return;
                        suggestionsList.cancelFlick();
                        const top = suggestionsList.originY;
                        const bottom = top + suggestionsList.contentHeight - suggestionsList.height;
                        suggestionsList.contentY = Math.max(top, Math.min(bottom, suggestionsList.contentY - delta));
                        event.accepted = true;
                    }
                }

                Controls.ScrollBar.vertical: Controls.ScrollBar {
                    id: suggestionScrollBar
                    anchors.right: suggestionsList.right
                    z: 1
                    policy: suggestionsList.contentHeight > suggestionsList.height
                        ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
                    width: Style.space(9)
                    padding: Style.space(2)
                    contentItem: Rectangle {
                        radius: width / 2
                        color: Util.alpha(root.foreground, suggestionScrollBar.pressed ? 0.8 : 0.48)
                    }
                }

                delegate: BorderSurface {
                    id: suggestionCard

                    required property string suggestionKey
                    required property string title
                    required property string reason
                    required property string pattern
                    required property string label
                    required property bool isPrivate
                    readonly property bool isApp: root.isAppTarget(label)
                    readonly property bool targetMissing: root.isMissingTarget(label)
                    readonly property bool invalidPrivate: isApp && isPrivate
                    readonly property string patternError: root.invalidPatternReason(pattern)
                    readonly property string warningText: root.suggestionError(pattern, label, isPrivate)
                    readonly property bool hasWarning: warningText !== ""
                    readonly property bool canStage: !hasWarning && !root.busy && !root._awaitingSave
                    function focusEdit() { suggestionEditButton.forceActiveFocus(); }

                    readonly property bool editing: root.editingSuggestionKey === suggestionKey
                    width: suggestionsList.width - (suggestionScrollBar.visible ? suggestionScrollBar.width : 0)
                    implicitHeight: cardColumn.implicitHeight + Style.spacing.xs * 2
                    color: editing ? Style.normalFillFor(root.foreground, root.accent) : "transparent"

                    ColumnLayout {
                        id: cardColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Style.spacing.xs
                        spacing: Style.spacing.xs

                        RowLayout {
                            Layout.fillWidth: true
                            visible: !suggestionCard.editing
                            spacing: Style.spacing.sm

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                spacing: Style.spacing.xxs
                                Text {
                                    Layout.fillWidth: true
                                    text: suggestionCard.title; textFormat: Text.PlainText
                                    color: root.foreground; font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: suggestionCard.pattern; textFormat: Text.PlainText
                                    color: Util.alpha(root.foreground, 0.65); font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption; wrapMode: Text.WrapAnywhere
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: "→ " + suggestionCard.label + (suggestionCard.isPrivate ? " · Private" : "")
                                    textFormat: Text.PlainText
                                    color: suggestionCard.targetMissing ? root.urgent : Util.alpha(root.foreground, 0.8)
                                    font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                                    wrapMode: Text.Wrap
                                }
                                Text {
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                    text: suggestionCard.hasWarning ? suggestionCard.warningText : suggestionCard.reason
                                    textFormat: Text.PlainText
                                    color: suggestionCard.hasWarning ? root.urgent : Util.alpha(root.foreground, 0.65)
                                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                                    wrapMode: Text.Wrap
                                }
                            }

                            Button {
                                id: suggestionEditButton
                                objectName: "suggestionEdit-" + suggestionCard.suggestionKey
                                text: "Edit"
                                fontSize: Style.font.bodySmall
                                foreground: Util.alpha(root.foreground, 0.75)
                                focusable: true
                                tooltipText: "Review or change the link pattern, target, and privacy"
                                onClicked: { root.editingSuggestionKey = suggestionCard.suggestionKey; root.rebuildSuggestions(); }
                            }

                            Button {
                                text: "Add"
                                fontSize: Style.font.bodySmall
                                bordered: true
                                enabled: suggestionCard.canStage
                                opacity: enabled ? 1 : 0.4
                                focusable: true
                                tooltipText: suggestionCard.hasWarning ? suggestionCard.warningText : root.autosave ? "Add a rule and save it automatically"
                                    : "Add a rule to the draft. Save changes to apply it."
                                onClicked: root.stageSuggestion(suggestionCard.suggestionKey)
                            }
                        }

                        Loader {
                            active: suggestionCard.editing
                            visible: active
                            Layout.fillWidth: true
                            sourceComponent: ColumnLayout {
                                spacing: Style.spacing.xs

                                Text {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: suggestionCard.title + (suggestionCard.reason ? " · " + suggestionCard.reason : "")
                                    color: Util.alpha(root.foreground, 0.75)
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    elide: Text.ElideRight
                                }

                                TextField {
                                    id: suggPatternField
                                    objectName: "suggestionPattern-" + suggestionCard.suggestionKey

                                    property string syncedText: suggestionCard.pattern

                                    Layout.fillWidth: true
                                    Layout.minimumWidth: Style.space(120)
                                    Layout.preferredHeight: Style.space(26)
                                    placeholderText: "Link pattern"
                                    foreground: root.foreground
                                    accent: root.accent
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    horizontalPadding: Style.spacing.md
                                    verticalPadding: Style.spacing.xs
                                    onSyncedTextChanged: {
                                        if (text !== syncedText)
                                            text = syncedText;

                                    }
                                    Component.onCompleted: {
                                        text = suggestionCard.pattern;
                                        cursorPosition = text.length;
                                        forceActiveFocus();
                                    }
                                    Keys.onEscapePressed: root.closeSuggestionEditor()
                                    onTextEdited: root.setSuggestionPattern(suggestionCard.suggestionKey, text)
                                    onAccepted: root.stageSuggestion(suggestionCard.suggestionKey)
                                }

                                Text {
                                    Layout.fillWidth: true
                                    visible: suggestionCard.hasWarning
                                    text: suggestionCard.warningText; textFormat: Text.PlainText
                                    wrapMode: Text.Wrap; color: root.urgent
                                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.spacing.md

                                    TargetPicker {
                                        tooltipText: "Choose where this suggestion opens matching links"
                                        Layout.preferredWidth: Style.space(156)
                                        Layout.minimumWidth: Style.space(104)
                                        subtle: false
                                        warning: suggestionCard.targetMissing
                                        value: suggestionCard.label
                                        options: root.ruleTargetOptions(suggestionCard.label)
                                        placeholderText: root.noneFoundLabel
                                        onPicked: function(val) {
                                            root.setSuggestionLabel(suggestionCard.suggestionKey, val);
                                        }
                                    }

                                    PrivateToggleButton {
                                        visible: !suggestionCard.isApp || suggestionCard.isPrivate
                                        active: suggestionCard.isPrivate
                                        invalid: suggestionCard.invalidPrivate
                                        enabled: !suggestionCard.isApp || suggestionCard.isPrivate
                                        tooltipText: suggestionCard.invalidPrivate ? suggestionCard.warningText : (suggestionCard.isApp ? "Private windows apply to browsers only" : (suggestionCard.isPrivate ? "Private window enabled — click to turn off" : "Open matching links in a private window"))
                                        onToggled: root.setSuggestionPrivate(suggestionCard.suggestionKey, !suggestionCard.isPrivate)
                                    }

                                    Text {
                                        visible: !suggestionCard.isApp || suggestionCard.isPrivate
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.setSuggestionPrivate(suggestionCard.suggestionKey, !suggestionCard.isPrivate)
                                        }
                                        text: "Private"; color: Util.alpha(root.foreground, 0.7)
                                        font.family: root.fontFamily; font.pixelSize: Style.font.caption
                                    }

                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Item { Layout.fillWidth: true }
                                    Button {
                                        text: "Close"
                                        tooltipText: "Collapse the editor and keep your suggestion edits"
                                        focusable: true
                                        onClicked: root.closeSuggestionEditor()
                                    }

                                    Button {
                                        enabled: suggestionCard.canStage
                                        opacity: enabled ? 1 : 0.4
                                        iconText: "󰄬"
                                        text: "Add to rules"
                                        bordered: true
                                        selected: enabled
                                        focusable: true
                                        foreground: root.foreground
                                        accent: root.accent
                                        fontFamily: root.fontFamily
                                        fontSize: Style.font.bodySmall
                                        iconSize: Style.font.iconSmall
                                        horizontalPadding: Style.spacing.lg
                                        verticalPadding: Style.spacing.xs
                                        tooltipText: suggestionCard.hasWarning ? suggestionCard.warningText : root.autosave ? "Add a rule and save it automatically"
                                            : "Add a rule to the draft. Save changes to apply it."
                                        onClicked: root.stageSuggestion(suggestionCard.suggestionKey)
                                    }

                                }

                            }
                        }
                        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

                    }

                }

            }

            // Empty and filtered Suggestions states
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - Style.spacing.huge * 2, Style.space(400))
                visible: root.activeTab === "suggestions" && suggestionsModel.count === 0
                spacing: Style.spacing.md
                Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText; horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.suggestionSearch.trim() || root.suggestionKind !== "all"
                        ? "No suggestions match these filters."
                        : "No new suggestions yet. Suggestions come from detected apps and repeated link choices."
                    color: Util.alpha(root.foreground, 0.65)
                    font.family: root.fontFamily; font.pixelSize: Style.font.body
                }
                Button {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.suggestionSearch.trim() || root.suggestionKind !== "all" ? "Clear filters" : "Rescan targets"
                    bordered: true; focusable: true
                    enabled: !root.busy && (root.suggestionSearch.trim() !== "" || root.suggestionKind !== "all" || !root.dirty)
                    opacity: enabled ? 1 : 0.4
                    tooltipText: root.dirty ? "Save or discard changes before rescanning targets." : "Find newly installed targets"
                    onClicked: {
                        if (root.suggestionSearch.trim() || root.suggestionKind !== "all") root.clearSuggestionFilters();
                        else root.requestRescan();
                    }
                }
            }

        }

        // Settings scroll independently while Save and Discard remain accessible.
        Flickable {
            id: settingsScroll
            objectName: "settingsScroll"
            visible: root.activeTab === "settings"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: settingsContent.implicitHeight + Style.spacing.sm
            function revealFocus(item) {
                if (!visible || !item) return;
                let ancestor = item;
                while (ancestor && ancestor !== settingsContent) ancestor = ancestor.parent;
                if (!ancestor) return;
                const point = item.mapToItem(contentItem, 0, 0);
                const margin = Style.spacing.sm;
                let nextY = contentY;
                if (point.y < contentY + margin) nextY = point.y - margin;
                else if (point.y + item.height > contentY + height - margin) nextY = point.y + item.height - height + margin;
                contentY = Math.max(0, Math.min(nextY, contentHeight - height));
            }
            Connections {
                target: root.Window.window
                function onActiveFocusItemChanged() {
                    Qt.callLater(() => settingsScroll.revealFocus(target.activeFocusItem));
                }
            }
            onHeightChanged: Qt.callLater(() => revealFocus(root.Window.window ? root.Window.window.activeFocusItem : null))
            boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollBar.vertical: Controls.ScrollBar {
                id: settingsScrollBar
                width: Style.space(9)
                policy: settingsScroll.contentHeight > settingsScroll.height ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
                padding: Style.space(2)
                anchors.right: settingsScroll.right
                contentItem: Rectangle { implicitWidth: Style.space(6); color: Util.alpha(root.foreground, 0.48); radius: width / 2 }
            }
            ColumnLayout {
                id: settingsContent
                width: settingsScroll.width - (settingsScrollBar.visible ? settingsScrollBar.width + Style.spacing.sm : 0)
                spacing: Style.spacing.md
                // Settings
                Toggle {
                    visible: root.activeTab === "settings"
                    Layout.fillWidth: true
                    enabled: root._hasLoadedDocument && !root.busy && !root._awaitingSave
                    opacity: enabled ? 1 : 0.4
                    label: "Autosave"
                    description: "Save valid rule edits and unmatched-link changes automatically."
                    checked: root.autosave
                    onClicked: {
                        root.statusMessage = "";
                        root.statusIsWarning = false;
                        root.statusShowRulesLink = false;
                        root.autosave = !root.autosave;
                        root.autosaveChosen(root.autosave);
                        root.scheduleAutosave();
                    }
                }

                RowLayout {
                    visible: root.activeTab === "settings"
                    enabled: root._hasLoadedDocument && !root.busy && !root._awaitingSave
                    opacity: enabled ? 1 : 0.4
                    Layout.fillWidth: true
                    spacing: Style.spacing.md

                    Text {
                        textFormat: Text.PlainText
                        text: "Unmatched links"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                    }

                    Text {
                        textFormat: Text.PlainText
                        text: "→"
                        color: Util.alpha(root.foreground, 0.55)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    TargetPicker {
                        id: fallbackPicker
                        tooltipText: "Choose what happens when no rule matches a link"

                        Layout.fillWidth: true
                        subtle: false
                        warning: root.fallbackMissing
                        value: root.draftFallback
                        options: root.fallbackTargetOptions()
                        placeholderText: root.askLabel
                        onPicked: function(val) {
                            root.setFallback(val);
                        }
                    }

                    WarningBadge {
                        visible: root.fallbackMissing
                        tooltipText: "Browser profile '" + root.draftFallback + "' not found — pick another or Rescan."
                    }

                }

                Text {
                    visible: root.fallbackMissing
                    Layout.fillWidth: true
                    text: "Unmatched-link target “" + root.draftFallback + "” is unavailable. Choose another browser profile or Always ask."
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }

                PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
                PanelSectionHeader {
                    visible: root.activeTab === "settings"
                    Layout.fillWidth: true
                    text: "System and detection"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                }

                Flow {
                    visible: root.activeTab === "settings"
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm
                    Button {
                        text: "Set as default link handler"
                        tooltipText: "Register Browser Picker to handle links opened from other apps"
                        bordered: true
                        focusable: true
                        enabled: !root.busy && !root._awaitingSave
                        opacity: enabled ? 1 : 0.4
                        onClicked: root.setupRequested(false)
                    }
                    Button {
                        text: "Refresh launchers"
                        tooltipText: "Update app launchers and command shortcuts"
                        bordered: true
                        focusable: true
                        enabled: !root.busy && !root._awaitingSave
                        opacity: enabled ? 1 : 0.4
                        onClicked: root.setupRequested(true)
                    }
                    Button {
                        objectName: "settingsRescan"
                        text: "Rescan targets"
                        tooltipText: "Find newly installed apps and browser profiles"
                        bordered: true
                        focusable: true
                        enabled: root._hasLoadedDocument && !root.busy && !root._awaitingSave && !root.dirty
                        opacity: enabled ? 1 : 0.4
                        onClicked: root.requestRescan()
                    }

                }

                Text {
                    visible: root.dirty
                    Layout.fillWidth: true
                    text: "Save or discard changes before rescanning targets."
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    color: Util.alpha(root.foreground, 0.7)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }

                Text {
                    visible: root.activeTab === "settings"
                    textFormat: Text.PlainText
                    text: root.browserTargets.length + " browser profiles · " + root.appTargets.length + " detected apps"
                    color: Util.alpha(root.foreground, 0.65)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm
                    Button {
                        visible: root.activeTab === "settings"
                        text: "Run recommended setup"
                        tooltipText: "Review web app profiles, app rules, and system setup"
                        bordered: true
                        focusable: true
                        enabled: !root.busy && !root._awaitingSave
                        opacity: enabled ? 1 : 0.4
                        onClicked: root.startRecommendedSetup()
                    }

                    Button {
                        visible: root.activeTab === "settings" && root.editorBackend !== ""
                        text: "Scan web app profiles"
                        tooltipText: "Find web app shortcuts that can open in the last-used browser profile"
                        bordered: true
                        focusable: true
                        enabled: !root.busy && !root._awaitingSave
                        opacity: enabled ? 1 : 0.4
                        onClicked: {
                            webappProfilesPopup.guided = false;
                            webappProfilesPopup.open();
                            webappProfilesPopup.scan();
                        }
                    }

                }

                PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
                PanelSectionHeader {
                    visible: root.activeTab === "settings"
                    Layout.fillWidth: true
                    text: "Help and feedback"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                }

                Flow {
                    visible: root.activeTab === "settings"
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm

                    Repeater {
                        model: [
                        { label: "Read the user guide", path: "/blob/HEAD/docs/CONFIGURATION.md", tooltip: "Open Browser Picker documentation on GitHub" },
                        { label: "Repository", tooltip: "Browse the source and project documentation on GitHub", path: "" },
                        { label: "Report an issue", tooltip: "Open the GitHub issue form for bugs or feature requests", path: "/issues/new/choose" },
                        { label: "Open a pull request", tooltip: "Compare branches on GitHub to propose a change", path: "/compare" }
                        ]
                        Button {
                            required property var modelData
                            text: modelData.label
                            tooltipText: modelData.tooltip
                            bordered: true
                            focusable: true
                            onClicked: Qt.openUrlExternally(root.docsUrl + modelData.path)
                        }
                    }
                }

                Item {
                    visible: root.activeTab === "settings"
                    Layout.fillWidth: true
                    Layout.preferredHeight: profileShortcuts.implicitHeight

                    ColumnLayout {
                        id: profileShortcuts
                        width: parent.width
                        spacing: Style.spacing.sm

                        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
                        PanelSectionHeader {
                            Layout.fillWidth: true
                            text: "Browser profiles in the app launcher"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Add a shortcut for each Chromium, Firefox, or Zen profile so you can open it directly from the app launcher. Sync only adds missing shortcuts and leaves existing ones in place."
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            color: Util.alpha(root.foreground, 0.72)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Toggle {
                            Layout.fillWidth: true
                            enabled: root.profileSyncLoaded && !root.profileSyncBusy && !root.busy && !root._awaitingSave
                            opacity: enabled ? 1 : 0.4
                            label: "Sync automatically"
                            description: "Add missing shortcuts when Browser Picker scans profiles while opening a link."
                            checked: root.profileSyncEnabled
                            onClicked: root.profileSyncToggled(!root.profileSyncEnabled)
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Button {
                                text: "Sync now"
                                tooltipText: "Add missing browser-profile shortcuts to the app launcher"
                                bordered: true
                                focusable: true
                                enabled: !root.profileSyncBusy && !root.busy && !root._awaitingSave
                                opacity: enabled ? 1 : 0.4
                                onClicked: root.profileSyncRequested()
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.profileSyncBusy ? "Working…" : root.profileSyncStatus
                                textFormat: Text.PlainText
                                wrapMode: Text.Wrap
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }
                        }
                    }
                }

            }
        }

        PanelSeparator {
            visible: root.activeTab === "settings" && (root.dirty || root._awaitingSave)
            Layout.fillWidth: true
            foreground: root.foreground
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.suggestionUndo !== null
            Text {
                Layout.fillWidth: true
                text: "Suggestion added to rules"; textFormat: Text.PlainText
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            }
            Button { id: suggestionUndoButton; text: "Undo"; bordered: true; focusable: true; enabled: !root.busy && !root._awaitingSave; onClicked: root.undoSuggestion() }
            Button { text: "Dismiss"; focusable: true; onClicked: root.suggestionUndo = null }
        }
        RowLayout {
            Layout.fillWidth: true
            visible: root.removalUndo.length > 0
            Text {
                Layout.fillWidth: true
                text: "Removed " + root.removalUndo.length + (root.removalUndo.length === 1 ? " rule" : " rules")
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
            Button {
                text: "Undo"
                focusable: true
                bordered: true
                enabled: !root.busy
                onClicked: root.undoRemoval()
            }
            Button {
                text: "Dismiss"
                focusable: true
                onClicked: root.removalUndo = []
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.dirty || root._awaitingSave
            Item { Layout.fillWidth: true }
            PanelActionButton {
                visible: root.dirty
                enabled: !root.busy && !root._awaitingSave
                opacity: enabled ? 1 : 0.4
                Accessible.name: "Discard unsaved changes"
                iconText: "󰕌"
                tooltipText: "Discard unsaved changes"
                foreground: root.foreground
                hoverColor: root.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.iconSmall
                focusable: true
                bordered: true
                onClicked: root.discardChanges()
            }

            Button {
                visible: root.dirty || root._awaitingSave
                enabled: !root.busy && root.dirty
                text: root.busy && root._awaitingSave ? "Saving…" : "Save changes"
                tooltipText: "Apply rule and unmatched-link changes (Ctrl+S)"
                selected: root.dirty && !root.busy
                bordered: true
                focusable: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.xl
                onClicked: root.requestSave()
            }
        }

        // Status / dirty / warning strip
        RowLayout {
            Layout.fillWidth: true
            visible: root.statusMessage !== "" || root.missingRuleCount > 0 || root.invalidPrivateCount > 0 || root.incompleteRuleCount > 0
            spacing: Style.spacing.md

            Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: {
                    if (root.statusIsWarning || root.invalidPrivateCount > 0)
                        return root.urgent;

                    if (root.dirty)
                        return root.accent;

                    return Util.alpha(root.foreground, 0.68);
                }
                text: {
                    if (root.statusMessage !== "")
                        return root.statusMessage;

                    if (root.incompleteRuleCount > 0)
                        return root.ruleSaveError(root.draftRules.find(rule => !rule.pattern.trim()
                            || !rule.label.trim() || rule.label === root.noneFoundLabel || root.invalidPatternReason(rule.pattern)));

                    if (root.invalidPrivateCount > 0)
                        return "⚠ " + root.invalidPrivateCount + " rule(s) mark a local app as private — pick a browser or turn off Private.";

                    if (root.missingRuleCount > 0)
                        return "⚠ " + root.missingRuleCount + " rule(s) reference a missing target.";

                    return "";
                }
            }

        }

    }

    Process {
        id: webappProfileWorker
        stdout: StdioCollector { id: webappProfileOutput }
        stderr: StdioCollector { id: webappProfileError }
        onExited: function(code, status) {
            if (code !== 0 || status !== 0) {
                webappProfilesPopup.message = webappProfileError.text.trim() || "Could not check web app profiles.";
                return;
            }
            try {
                const result = JSON.parse(webappProfileOutput.text);
                if (result.pinned) {
                    webappProfilesPopup.apps = webappProfilesPopup.apps.filter(app => app.id !== result.pinned);
                    webappProfilesPopup.message = "Saved the profile to this web app shortcut.";
                } else {
                    webappProfilesPopup.apps = result.apps;
                    webappProfilesPopup.message = result.apps.length
                        ? "Choose a profile for each launcher you want to pin."
                        : "No shortcuts need pinning among the web apps this scan supports.";
                }
            } catch (error) {
                webappProfilesPopup.message = "Could not read the web app profile scan.";
            }
        }
    }

    Controls.Popup {
        id: webappProfilesPopup
        closePolicy: Controls.Popup.CloseOnEscape
        property bool guided: false
        property var apps: []
        property string message: ""
        function scan() {
            if (webappProfileWorker.running)
                return;
            apps = [];
            message = "Checking web app launchers…";
            webappProfileWorker.command = [root.editorBackend, "scan-webapp-profiles"];
            webappProfileWorker.running = true;
        }
        function pin(app, profile) {
            if (webappProfileWorker.running)
                return;
            message = "Updating launcher…";
            webappProfileWorker.command = [root.editorBackend, "pin-webapp-profile",
                JSON.stringify({ id: app.id, revision: app.revision, profile: profile })];
            webappProfileWorker.running = true;
        }

        anchors.centerIn: parent
        width: Math.min(root.width - Style.space(24), Style.space(560))
        height: Math.min(root.height - Style.space(24), Style.space(480))
        padding: Style.space(16)
        modal: true
        Controls.Overlay.modal: Rectangle { color: Util.alpha(root.background, 0.68) }
        focus: true
        background: BorderSurface {
            color: root.popupBackground
            borderSpec: Border.flat(root.accent, 1)
            radius: Style.cornerRadius
        }
        contentItem: ColumnLayout {
            spacing: Style.spacing.md
            SetupHeading {
                Layout.fillWidth: true
                text: "Web app profiles"
                onCloseRequested: webappProfilesPopup.close()
            }
            Text {
                Layout.fillWidth: true
                text: "By default if you have multiple chrome profiles in omarchy webapps will just open \"random\" profiles each time you open that web app based on what profile you had open last. Keep an Omarchy web app in the browser profile that has the right account."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
            SetupHelp {
                text: "Read more about web app profiles ↗"
                url: root.docsUrl + "/blob/HEAD/docs/CONFIGURATION.md#web-app-profiles"
            }
            PanelSeparator {
                Layout.fillWidth: true
                foreground: root.foreground
            }

            Text {
                Layout.fillWidth: true
                text: webappProfilesPopup.message
                maximumLineCount: 3
                elide: Text.ElideRight
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
            ListView {
                id: webappProfileList
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                clip: true
                spacing: Style.spacing.sm
                model: webappProfilesPopup.apps
                Controls.ScrollBar.vertical: Controls.ScrollBar { id: webappProfileScroll }
                delegate: RowLayout {
                    id: webappProfileRow
                    required property var modelData
                    width: webappProfileList.width - (webappProfileScroll.size < 1 ? webappProfileScroll.width + spacing : 0)
                    Text {
                        Layout.fillWidth: true
                        text: webappProfileRow.modelData.name
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                    TargetPicker {
                        id: webappProfilePicker
                        Layout.preferredWidth: Math.min(Style.space(220), webappProfileRow.width * 0.48)
                        options: webappProfileRow.modelData.profiles
                        placeholderText: "Choose profile"
                        tooltipText: "Choose the browser profile this web app should always use"
                        enabled: !webappProfileWorker.running
                        onPicked: val => value = val
                    }
                    Button {
                        text: "Pin profile"
                        tooltipText: "Update this shortcut to always launch in the selected profile"
                        bordered: true
                        focusable: true
                        enabled: webappProfilePicker.value !== "" && !webappProfileWorker.running
                        onClicked: webappProfilesPopup.pin(webappProfileRow.modelData, webappProfilePicker.value)
                    }
                }
            }
            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button {
                    text: "Scan again"
                    tooltipText: "Check the current web app shortcuts again"
                    focusable: true
                    enabled: !webappProfileWorker.running
                    onClicked: webappProfilesPopup.scan()
                }
                Button {
                    visible: webappProfilesPopup.guided
                    text: "Back"
                    tooltipText: "Return to optional setup"
                    focusable: true
                    onClicked: webappProfilesPopup.close()
                }
            }
        }
    }

    Controls.Popup {
        id: appSetupPopup
        closePolicy: Controls.Popup.CloseOnEscape
        anchors.centerIn: parent
        width: Math.min(root.width - Style.space(24), Style.space(560))
        height: Math.min(root.height - Style.space(24), Style.space(480))
        padding: Style.space(16)
        modal: true
        Controls.Overlay.modal: Rectangle { color: Util.alpha(root.background, 0.68) }
        focus: true
        background: BorderSurface {
            color: root.popupBackground
            borderSpec: Border.flat(root.accent, 1)
            radius: Style.cornerRadius
        }

        contentItem: ColumnLayout {
            spacing: Style.spacing.md

            SetupHeading {
                Layout.fillWidth: true
                text: root.editorBackend === "" ? "Recommended app rules" : "2 of 3 · Recommended app rules"
                onCloseRequested: appSetupPopup.close()
            }

            Text {
                Layout.fillWidth: true
                text: "Choose apps that should open their own links automatically. For example, a Zoom meeting link can open directly in Zoom."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
            }

            SetupHelp {
                text: "Read more about app rules ↗"
                url: root.docsUrl + "/blob/HEAD/docs/CONFIGURATION.md#local-apps--web-apps-appsconf"
            }
            PanelSeparator {
                Layout.fillWidth: true
                foreground: root.foreground
            }

            ListView {
                id: onboardingList
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                clip: true
                spacing: Style.spacing.xs
                model: root.onboardingCandidates
                Controls.ScrollBar.vertical: Controls.ScrollBar {
                    id: onboardingScroll
                    anchors.right: onboardingList.right
                    policy: onboardingList.contentHeight > onboardingList.height
                        ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
                }
                delegate: SelectionCheck {
                    id: appChoice
                    required property var modelData
                    width: onboardingList.width - (onboardingScroll.visible ? onboardingScroll.width + Style.spacing.xs : 0)
                    leftPadding: Style.space(7)
                    rightPadding: Style.space(7)
                    topPadding: Style.space(5)
                    bottomPadding: Style.space(5)
                    checked: root.onboardingSelection["pattern:" + modelData.pattern] === modelData.label
                    Accessible.name: modelData.label + ", " + modelData.pattern
                    onClicked: root.toggleOnboardingApp(modelData)
                    onActiveFocusChanged: if (activeFocus) onboardingList.positionViewAtIndex(index, ListView.Contain)
                    required property int index
                    background: Rectangle {
                        color: appChoice.activeFocus || appChoice.hovered
                            ? Util.alpha(root.foreground, 0.08) : "transparent"
                    }
                    contentItem: Column {
                        leftPadding: Style.space(25)
                        spacing: Style.spacing.xxs
                        Text {
                            width: parent.width - parent.leftPadding
                            text: String(appChoice.modelData.label).replace(/ — Web App$/, "")
                            textFormat: Text.PlainText
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width - parent.leftPadding
                            text: appChoice.modelData.label === "Zoom" && appChoice.modelData.pattern.startsWith("regex:")
                                ? "zoom.us meeting links → Zoom app" : appChoice.modelData.pattern
                            textFormat: Text.PlainText
                            color: Util.alpha(root.foreground, 0.73)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                        }
                    }
                }
                Text {
                    visible: onboardingList.count === 0
                    anchors.top: parent.top
                    anchors.left: parent.left
                    text: "No new app rules to add."
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button {
                    text: root.editorBackend === "" ? "Cancel" : "Back"
                    tooltipText: root.editorBackend === "" ? "Close setup" : "Return to default link handling"
                    focusable: true
                    onClicked: {
                        appSetupPopup.close();
                        if (root.editorBackend !== "") {
                            systemSetupPopup.extras = false;
                            systemSetupPopup.open();
                        }
                    }
                }
                Button {
                    readonly property int selectionCount: root.onboardingCandidates.filter(
                        item => root.onboardingSelection["pattern:" + item.pattern] === item.label).length
                    readonly property bool hasSelection: selectionCount > 0
                    text: root.editorBackend === ""
                        ? (hasSelection ? "Add rules and finish" : "Finish")
                        : (hasSelection ? "Add " + selectionCount + (selectionCount === 1 ? " rule" : " rules") : "Next")
                    tooltipText: hasSelection
                        ? (root.autosave ? "Add rules for the checked apps and save automatically"
                            : "Add rules for the checked apps to the draft")
                        : "Continue without adding app rules"
                    focusable: true
                    bordered: true
                    enabled: !hasSelection || !root.busy
                    selected: enabled
                    onClicked: hasSelection ? root.addOnboardingApps() : root.advanceAppSetup()
                }
            }
        }
    }

    Controls.Popup {
        id: systemSetupPopup
        property bool extras: false
        closePolicy: Controls.Popup.CloseOnEscape
        anchors.centerIn: parent
        width: Math.min(root.width - Style.space(24), Style.space(560))
        height: Math.min(root.height - Style.space(24), Style.space(480))
        padding: Style.space(16)
        modal: true
        Controls.Overlay.modal: Rectangle { color: Util.alpha(root.background, 0.68) }
        focus: true
        background: BorderSurface {
            color: root.popupBackground
            borderSpec: Border.flat(root.accent, 1)
            radius: Style.cornerRadius
        }
        contentItem: ColumnLayout {
            spacing: Style.spacing.md
            SetupHeading {
                Layout.fillWidth: true
                text: systemSetupPopup.extras ? "3 of 3 · Optional extras" : "1 of 3 · Set up link handling"
                onCloseRequested: systemSetupPopup.close()
            }
            Text {
                Layout.fillWidth: true
                text: systemSetupPopup.extras ? "Choose the extras that fit how you work."
                    : "Choose which links open through Browser Better Default."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
            Controls.ScrollView {
                id: systemScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                clip: true
                contentWidth: Math.max(0, availableWidth - Style.space(14))
                Controls.ScrollBar.vertical: Controls.ScrollBar {
                    anchors.top: systemScroll.top
                    anchors.right: systemScroll.right
                    anchors.bottom: systemScroll.bottom
                    policy: systemScroll.contentHeight > systemScroll.availableHeight
                        ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
                }
                ColumnLayout {
                    id: systemActions
                    width: systemScroll.contentWidth
                    spacing: Style.spacing.md

                    SetupAction {
                        Layout.fillWidth: true
                        visible: !systemSetupPopup.extras
                        title: "Open links with Browser Better Default"
                        description: "Set Browser Better Default as your default so most links you click go through it. If no rule matches, it asks where to open the link unless you’ve chosen a default profile."
                        actionText: "Set as default"
                        status: root.defaultHandlerStatus
                        failed: root.defaultHandlerFailed
                        onActivated: root.setupRequested(false)
                    }
                    PanelSeparator { visible: !systemSetupPopup.extras; Layout.fillWidth: true; foreground: root.foreground }
                    SetupAction {
                        Layout.fillWidth: true
                        visible: !systemSetupPopup.extras
                        title: "Open links from web apps"
                        description: "When you click a link in a Chromium web app like WhatsApp, the extension sends it to Browser Better Default so your rules decide where it opens. Without the extension, the link can open in the web app’s current browser profile."
                        actionText: "Install extension"
                        helpUrl: root.docsUrl + "/blob/HEAD/docs/BRIDGE.md"
                        status: root.bridgeStatus
                        failed: !root.bridgeBusy && root.bridgeFailed
                        onActivated: root.bridgeInstallRequested()
                    }
                    SetupAction {
                        Layout.fillWidth: true
                        visible: systemSetupPopup.extras
                        title: "Web app profiles"
                        description: "By default if you have multiple chrome profiles in omarchy webapps will just open \"random\" profiles each time you open that web app based on what profile you had open last. Keep an Omarchy web app in the browser profile that has the right account."
                        actionText: "Review profiles"
                        onActivated: {
                            webappProfilesPopup.guided = true
                            webappProfilesPopup.open()
                            webappProfilesPopup.scan()
                        }
                    }
                    PanelSeparator { visible: systemSetupPopup.extras; Layout.fillWidth: true; foreground: root.foreground }
                    SetupAction {
                        Layout.fillWidth: true
                        visible: systemSetupPopup.extras
                        title: "Profile shortcuts"
                        description: "Add shortcuts for your browser profiles so you can launch Work or Personal right from the app menu (Super+Space)."
                        actionText: "Create shortcuts"
                        status: root.profileSyncBusy ? "Creating profile shortcuts…"
                            : (root.setupProfileSyncStatus ? "Last run · " + root.setupProfileSyncStatus : "")
                        failed: !root.profileSyncBusy && root.setupProfileSyncFailed
                        onActivated: root.profileSyncRequested()
                    }

                }
            }
            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button {
                    visible: systemSetupPopup.extras
                    text: "Back"
                    focusable: true
                    onClicked: {
                        systemSetupPopup.close()
                        appSetupPopup.open()
                    }
                }
                Button {
                    text: systemSetupPopup.extras ? "Finish" : "Next"
                    selected: true
                    tooltipText: systemSetupPopup.extras ? "Close recommended setup" : "Continue to recommended app rules"
                    bordered: true
                    focusable: true
                    onClicked: {
                        if (systemSetupPopup.extras) {
                            root.finishRecommendedSetup()
                        } else {
                            systemSetupPopup.close()
                            appSetupPopup.open()
                        }
                    }
                }
            }
        }
    }

    component SetupHeading: RowLayout {
        id: heading
        required property string text
        signal closeRequested()

        Text {
            Layout.fillWidth: true
            text: heading.text
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
        }
        Button {
            text: "×"
            tooltipText: "Close setup"
            Accessible.name: "Close setup"
            focusable: true
            onClicked: heading.closeRequested()
        }
    }

    component SetupHelp: Button {
        required property string url
        bordered: false
        focusable: true
        foreground: root.accent
        horizontalPadding: 0
        verticalPadding: Style.spacing.xxs
        Accessible.role: Accessible.Link
        Accessible.name: text
        fontSize: Style.font.bodySmall
        onClicked: Qt.openUrlExternally(url)
    }

    component SetupAction: ColumnLayout {
        id: action
        required property string title
        required property string description
        required property string actionText
        property string helpUrl: ""
        property string status: ""
        property bool failed: false
        property bool showDetails: false
        readonly property int detailStart: status.indexOf("\n")
        signal activated()
        onStatusChanged: showDetails = false
        spacing: Style.spacing.xs

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: action.title
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
            }
            Button {
                text: action.failed ? "Retry" : action.actionText
                Accessible.name: action.failed ? "Retry " + action.title : action.actionText
                fontSize: Style.font.caption
                bordered: true
                focusable: true
                enabled: !root.busy && !root.profileSyncBusy && !root.bridgeBusy
                opacity: enabled ? 1 : 0.5
                onClicked: action.activated()
            }
        }
        Text {
            Layout.fillWidth: true
            text: action.description
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Util.alpha(root.foreground, 0.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
        }
        SetupHelp {
            visible: action.helpUrl !== ""
            text: "Read more about the extension ↗"
            url: action.helpUrl
        }
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: action.detailStart < 0 ? action.status : action.status.slice(0, action.detailStart)
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: action.failed ? root.disabledTint : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
        Button {
            visible: action.detailStart >= 0
            text: action.showDetails ? "Hide details" : "Show details"
            foreground: root.accent
            horizontalPadding: 0
            fontSize: Style.font.caption
            focusable: true
            onClicked: action.showDetails = !action.showDetails
        }
        TextEdit {
            Layout.fillWidth: true
            visible: action.showDetails && action.detailStart >= 0
            text: visible ? action.status.slice(action.detailStart + 1) : ""
            textFormat: TextEdit.PlainText
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            color: root.disabledTint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
    }

    FocusScope {
        id: removalOverlay
        anchors.fill: parent
        z: 20
        visible: root.pendingRemoval.length > 0
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: event => {
            confirmRemove.handleKey(event);
            event.accepted = true;
        }
        ConfirmDialog {
            id: confirmRemove
            anchors.fill: parent
            opened: removalOverlay.visible
            message: root.removalMessage()
            confirmText: "Remove"
            onCanceled: root.finishRemoval(false)
            onConfirmed: root.finishRemoval(true)
        }
    }

    component ShiftRemoveClick: MouseArea {
        anchors.fill: parent
        z: 1
        signal shiftClicked()
        onPressed: mouse => {
            mouse.accepted = !!(mouse.modifiers & Qt.ShiftModifier);
        }
        onClicked: shiftClicked()
    }

    component HelpDropdown: Dropdown {
        id: dropdown
        property string tooltipText: ""
        HoverHandler { id: dropdownHover }
        PanelToolTip {
            visible: dropdownHover.hovered && !dropdown.popupOpen
            text: dropdown.tooltipText
            fontFamily: root.fontFamily
        }
    }

    component SelectionCheck: Controls.CheckBox {
        id: selection
        property string tooltipText: ""
        hoverEnabled: true
        padding: 0
        PanelToolTip {
            visible: selection.hovered && selection.tooltipText !== ""
            text: selection.tooltipText
            fontFamily: root.fontFamily
        }
        indicator: BorderSurface {
            implicitWidth: Style.space(15)
            implicitHeight: Style.space(15)
            color: selection.checkState !== Qt.Unchecked ? root.accent : "transparent"
            borderSpec: Border.flat(root.accent, selection.activeFocus ? 2 : 1)
            Text {
                anchors.centerIn: parent
                text: selection.checkState === Qt.PartiallyChecked ? "−" : selection.checked ? "✓" : ""
                textFormat: Text.PlainText
                color: root.background
                font.pixelSize: Style.font.caption
            }
        }
    }

    // Viewport-aware single-select target picker matching qs.Ui.Dropdown visuals
    // while flipping upward near the bottom edge and expanding cleanly inside
    // ~598px tiled windows.
    component TargetPicker: Item {
        id: picker

        property string value: ""
        property var options: []
        property string placeholderText: ""
        property string tooltipText: ""
        property bool subtle: false
        property bool warning: false
        property color foreground: root.foreground
        property color popupBackground: root.popupBackground
        property color popupBorder: root.popupBorder
        property color accent: root.accent
        property color urgent: root.urgent
        property string fontFamily: root.fontFamily
        property int rowHeight: Style.space(26)
        property int popupRowHeight: Style.spacing.popupRowHeight
        readonly property var _popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Commons.Color.popups.border, Style.normalBorderWidth)

        signal picked(string value)

        function currentLabel() {
            for (var i = 0; i < options.length; i++) {
                var o = options[i];
                var v = o && typeof o === "object" ? String(o.value) : String(o);
                if (v === value)
                    return o && typeof o === "object" ? String(o.label) : String(o);

            }
            return value !== "" ? value : placeholderText;
        }

        implicitWidth: Style.space(156)
        implicitHeight: rowHeight

        BorderSurface {
            id: trigger

            readonly property bool _focused: trigger.activeFocus || popup.opened
            readonly property bool _hot: triggerHover.hovered

            anchors.fill: parent
            radius: Style.cornerRadius
            color: _focused ? Style.focusFillFor(picker.foreground, picker.accent) : (_hot ? Style.hoverFillFor(picker.foreground, picker.accent) : (picker.subtle ? "transparent" : Style.normalFillFor(picker.foreground, picker.accent)))
            borderSpec: _focused ? Border.controlSpec("focus", picker.foreground, picker.accent) : (_hot ? Border.controlSpec("hover-cursor", picker.foreground, picker.accent) : (picker.subtle ? Border.none() : Border.controlSpec("normal", picker.foreground, picker.accent)))
            activeFocusOnTab: true
            Accessible.role: Accessible.ComboBox
            Accessible.name: picker === fallbackPicker ? "Unmatched links: " + picker.currentLabel() : picker.currentLabel()
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
                    popup.opened ? popup.close() : popup.open();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape && popup.opened) {
                    popup.close();
                    event.accepted = true;
                }
            }

            HoverHandler {
                id: triggerHover
            }

            Text {
                id: valueLabel

                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: chevron.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: trigger.borderLeft + Style.spacing.md
                anchors.rightMargin: Style.spacing.sm
                text: picker.currentLabel()
                color: picker.warning ? picker.urgent : picker.foreground
                font.family: picker.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
            }

            Text {
                id: chevron

                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: trigger.borderRight + Style.spacing.md
                text: "󰅀"
                color: Util.alpha(picker.foreground, 0.72)
                font.family: picker.fontFamily
                font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
                id: triggerMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    trigger.forceActiveFocus();
                    popup.opened ? popup.close() : popup.open();
                }
            }

            PanelToolTip {
                visible: triggerMouse.containsMouse && !popup.opened && text !== ""
                text: valueLabel.truncated && picker.tooltipText !== ""
                    ? picker.currentLabel() + "\n" + picker.tooltipText
                    : (valueLabel.truncated ? picker.currentLabel() : picker.tooltipText)
                fontFamily: picker.fontFamily
            }

            Controls.Popup {
                id: popup

                x: 0
                y: trigger.height + Style.spacing.xxs
                width: trigger.width
                closePolicy: Controls.Popup.CloseOnPressOutsideParent | Controls.Popup.CloseOnEscape
                implicitHeight: Math.min(picker.options.length * picker.popupRowHeight + Math.max(0, picker.options.length - 1) * Style.spacing.xxs, picker.popupRowHeight * 8 + 7 * Style.spacing.xxs) + topPadding + bottomPadding
                padding: Style.spacing.hairline
                leftPadding: Border.left(picker._popupBorderSpec) + Style.spacing.hairline
                rightPadding: Border.right(picker._popupBorderSpec) + Style.spacing.hairline
                topPadding: Border.top(picker._popupBorderSpec) + Style.spacing.hairline
                bottomPadding: Border.bottom(picker._popupBorderSpec) + Style.spacing.hairline
                focus: true
                onAboutToShow: {
                    if (root.width <= 0 || root.height <= 0)
                        return ;

                    const position = trigger.mapToItem(root, 0, 0);
                    popup.width = Math.max(trigger.width, Math.min(Style.space(236), root.width));
                    // Wide fields keep both edges aligned. Narrow fields may
                    // expand toward whichever side has room.
                    popup.x = Math.min(0, root.width - position.x - popup.width);
                    const gap = Style.spacing.xxs;
                    const below = Math.max(1, root.height - position.y - trigger.height - gap);
                    const above = Math.max(1, position.y - gap);
                    const openAbove = below < popup.implicitHeight && above > below;
                    popup.height = Math.min(popup.implicitHeight, openAbove ? above : below);
                    popup.y = openAbove ? -popup.height - gap : trigger.height + gap;
                }
                onOpened: {
                    optionList.currentIndex = Math.max(0, optionList.indexOfValue(picker.value));
                    optionList.forceActiveFocus();
                }

                background: BorderSurface {
                    color: picker.popupBackground
                    borderSpec: picker._popupBorderSpec
                    radius: Style.cornerRadius
                }

                contentItem: ListView {
                    id: optionList

                    function indexOfValue(v) {
                        for (var i = 0; i < picker.options.length; i++) {
                            var o = picker.options[i];
                            var ov = o && typeof o === "object" ? String(o.value) : String(o);
                            if (ov === v)
                                return i;

                        }
                        return -1;
                    }

                    function selectCurrent() {
                        if (currentIndex < 0 || currentIndex >= picker.options.length)
                            return ;

                        var o = picker.options[currentIndex];
                        var v = o && typeof o === "object" ? String(o.value) : String(o);
                        picker.picked(v);
                        popup.close();
                    }

                    spacing: Style.spacing.xxs
                    implicitHeight: contentHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: picker.options
                    currentIndex: -1
                    Keys.priority: Keys.BeforeItem
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                            popup.close();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down || event.text === "j") {
                            optionList.currentIndex = Math.min(picker.options.length - 1, optionList.currentIndex + 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up || event.text === "k") {
                            optionList.currentIndex = Math.max(0, optionList.currentIndex - 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            optionList.selectCurrent();
                            event.accepted = true;
                        }
                    }

                    Controls.ScrollBar.vertical: Controls.ScrollBar {
                        id: optionScrollBar
                        anchors.right: optionList.right
                        z: 1
                        policy: optionList.contentHeight > optionList.height
                            ? Controls.ScrollBar.AlwaysOn : Controls.ScrollBar.AlwaysOff
                        width: Style.space(9)
                        padding: Style.space(2)
                        contentItem: Rectangle {
                            radius: width / 2
                            color: Util.alpha(picker.foreground, optionScrollBar.pressed ? 0.8 : 0.48)
                        }
                    }

                    delegate: Rectangle {
                        id: optRow

                        required property var modelData
                        required property int index
                        readonly property string optValue: modelData && typeof modelData === "object" ? String(modelData.value) : String(modelData)
                        readonly property string optLabel: modelData && typeof modelData === "object" ? String(modelData.label) : String(modelData)
                        readonly property string optTag: modelData && typeof modelData === "object" && modelData.tag ? String(modelData.tag) : ""
                        readonly property bool isCurrent: index === optionList.currentIndex
                        readonly property bool isSelected: optValue === picker.value

                        width: optionList.width - (optionScrollBar.visible ? optionScrollBar.width : 0)
                        height: picker.popupRowHeight
                        color: isCurrent ? Style.hoverFillFor(picker.foreground, picker.accent) : (isSelected ? Style.selectedFillFor(picker.foreground, picker.accent) : "transparent")

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.spacing.controlPaddingX
                            anchors.rightMargin: Style.spacing.controlPaddingX
                            spacing: Style.spacing.md

                            Text {
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: optLabel
                                color: optTag === "missing" ? picker.urgent : (isCurrent ? Style.hoverStateColor(picker.foreground, picker.accent) : picker.foreground)
                                font.family: picker.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                font.bold: isSelected
                                elide: Text.ElideRight
                            }

                            Text {
                                visible: optTag !== ""
                                textFormat: Text.PlainText
                                text: optTag
                                color: optTag === "missing" ? picker.urgent : Util.alpha(picker.foreground, 0.55)
                                font.family: picker.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: optionList.currentIndex = optRow.index
                            onClicked: optionList.selectCurrent()
                        }

                    }

                }

            }

        }

    }

    // Compact private-window toggle button following Omarchy Style state tokens.
    component PrivateToggleButton: BorderSurface {
        id: privBtn

        property bool active: false
        property bool invalid: false
        property string tooltipText: ""
        property color foreground: root.foreground
        property color accent: root.accent
        property color urgent: root.urgent
        property string fontFamily: root.fontFamily
        property real size: Math.round(Math.max(Style.space(22), Style.font.iconSmall + Style.spacing.sm * 2)) | 1
        readonly property bool _hot: privMouse.containsMouse && privBtn.enabled
        readonly property color _tintColor: invalid ? urgent : accent

        signal toggled()

        implicitWidth: size
        implicitHeight: size
        radius: Style.cornerRadius
        activeFocusOnTab: enabled
        Accessible.role: Accessible.CheckBox
        Accessible.name: "Private window"
        Accessible.checkable: true
        Accessible.checked: active
        Accessible.onPressAction: if (enabled) toggled()
        color: activeFocus ? Style.focusFillFor(foreground, _tintColor) : (_hot ? Style.hoverFillFor(foreground, _tintColor) : (active ? Style.selectedFillFor(foreground, _tintColor) : "transparent"))
        borderSpec: activeFocus ? Border.controlSpec("focus", foreground, _tintColor) : (active ? Border.flat(Util.alpha(_tintColor, 0.55), 1) : (_hot ? Border.controlSpec("hover-cursor", foreground, _tintColor) : Border.none()))
        Keys.onReturnPressed: {
            if (enabled)
                toggled();

        }
        Keys.onEnterPressed: {
            if (enabled)
                toggled();

        }
        Keys.onSpacePressed: {
            if (enabled)
                toggled();

        }

        Text {
            textFormat: Text.PlainText
            x: Math.round((privBtn.width - width) / 2)
            y: Math.round((privBtn.height - height) / 2)
            text: "󰈉"
            color: !privBtn.enabled ? Util.alpha(privBtn.foreground, 0.28) : (privBtn.invalid ? privBtn.urgent : (privBtn.active ? privBtn.accent : Util.alpha(privBtn.foreground, privBtn._hot ? 0.68 : 0.3)))
            font.family: privBtn.fontFamily
            font.pixelSize: Style.font.iconSmall
        }

        MouseArea {
            id: privMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: privBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
                if (privBtn.enabled)
                    privBtn.toggled();

            }
        }

        PanelToolTip {
            visible: privBtn.tooltipText !== "" && privMouse.containsMouse
            text: privBtn.tooltipText
            fontFamily: privBtn.fontFamily
        }

        Behavior on color {
            ColorAnimation {
                duration: Style.duration(80)
            }

        }

    }

    // Compact warning glyph with tooltip for missing profiles or invalid combos.
    component WarningBadge: Item {
        id: warnItem

        property string tooltipText: ""
        property color urgent: root.urgent
        property string fontFamily: root.fontFamily

        implicitWidth: Style.space(18)
        implicitHeight: Style.space(22)

        Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "⚠"
            color: warnItem.urgent
            font.family: warnItem.fontFamily
            font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
            id: warnMouse

            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
            visible: warnItem.tooltipText !== "" && warnMouse.containsMouse
            text: warnItem.tooltipText
            fontFamily: warnItem.fontFamily
        }

    }

}
