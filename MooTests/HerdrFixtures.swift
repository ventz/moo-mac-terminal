//
//  HerdrFixtures.swift
//  MooTests
//
//  herdr 0.9.3's own words, captured from a real server on 2026-10-04
//  (snapshot, focus reply, errors, and the event streams). Not written by
//  hand, so field names and the mix of "pane.x" / "pane_x" event names are
//  what herdr really sends.
//

enum HerdrFixtures {
    static let snapshotWithBlockedAgent = #"{"id":"s1","result":{"type":"session_snapshot","snapshot":{"version":"0.9.3","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","number":1,"label":"api","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"blocked"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":true,"pane_count":1,"agent_status":"blocked"}],"panes":[{"pane_id":"w1:p1","terminal_id":"term_65d099c5a6c7d1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","foreground_cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","agent":"claude","agent_status":"blocked","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":40},"revision":0}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":120,"height":40},"focused_pane_id":"w1:p1","panes":[{"pane_id":"w1:p1","focused":true,"rect":{"x":0,"y":0,"width":120,"height":40}}],"splits":[]}],"agents":[{"terminal_id":"term_65d099c5a6c7d1","agent":"claude","agent_status":"blocked","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"state_change_seq":2,"cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","foreground_cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","revision":0}]}}}"#

    static let agentFocusReply = #"{"id":"f2","result":{"type":"agent_info","agent":{"terminal_id":"term_65d099c5a6c7d1","agent":"claude","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"state_change_seq":4,"cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","foreground_cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","revision":0}}}"#

    static let unknownPaneSubscribe = #"{"id":"e1","error":{"code":"pane_not_found","message":"pane w9:p9 not found"}}"#

    static let subscriptionStarted = #"{"id":"status","result":{"type":"subscription_started"}}"#

    static let statusWorking = #"{"data":{"agent":"claude","agent_status":"working","pane_id":"w1:p1","workspace_id":"w1"},"event":"pane.agent_status_changed"}"#
    static let statusBlocked = #"{"data":{"agent":"claude","agent_status":"blocked","pane_id":"w1:p1","workspace_id":"w1"},"event":"pane.agent_status_changed"}"#
    static let statusIdle = #"{"data":{"agent":"claude","agent_status":"idle","pane_id":"w1:p1","workspace_id":"w1"},"event":"pane.agent_status_changed"}"#

    static let agentDetected = #"{"data":{"agent":"claude","pane_id":"w1:p1","type":"pane_agent_detected","workspace_id":"w1"},"event":"pane_agent_detected"}"#
    /// From the 2026-10-04 spike: Claude Code exiting.
    static let agentReleased = #"{"data":{"agent":"claude","final_status":"idle","pane_id":"w1:p4","released":true,"type":"pane_agent_detected","workspace_id":"w1"},"event":"pane_agent_detected"}"#

    static let paneCreated = #"{"data":{"pane":{"agent_status":"unknown","cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","focused":false,"foreground_cwd":"/private/var/folders/w3/3yyfv4fn475dzs433lf2wnfw0000gn/T/hc.tQ7uWO","pane_id":"w1:p2","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":40},"tab_id":"w1:t1","terminal_id":"term_65d099c8749682","workspace_id":"w1"},"type":"pane_created"},"event":"pane_created"}"#
    static let paneClosed = #"{"data":{"pane_id":"w1:p2","type":"pane_closed","workspace_id":"w1"},"event":"pane_closed"}"#

    /// Shape from herdr's socket API docs; not reproducible on demand.
    static let eventsLost = #"{"id":"lifecycle","error":{"code":"events_lost","message":"subscriber fell behind"}}"#
}
