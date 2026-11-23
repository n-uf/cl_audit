// The status record is cl_kit's (ProfileCore's StatusRecord, StatusCodec, StatusAges): status/<profile>.json, one shape
// for cl_audit and its Dock icons, which only ever gains fields. cl_audit's files still call it IconStatus while
// feat/two-names owns AccountResolver.swift, Launcher.swift and Settings.swift; once that lands, they say StatusRecord in
// one rename and this file goes.

import ProfileCore

typealias IconStatus = StatusRecord
