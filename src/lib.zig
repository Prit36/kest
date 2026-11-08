//! Everything below the UI, importable by tests and benchmarks.
const std = @import("std");
const builtin = @import("builtin");

pub const request = @import("core/request.zig");
pub const key_value_text = @import("core/key_value_text.zig");
pub const environment = @import("core/environment.zig");
pub const variables = @import("core/variables.zig");
pub const completion = @import("core/completion.zig");
pub const json_tree = @import("core/json_tree.zig");
pub const json_path = @import("core/json_path.zig");
pub const collection = @import("core/collection.zig");
pub const history = @import("core/history.zig");
pub const json = @import("utils/json.zig");
pub const url = @import("utils/url.zig");
pub const curl = @import("import_export/curl.zig");
pub const postman = @import("import_export/postman.zig");
pub const native_format = @import("import_export/native_format.zig");
pub const doc = @import("import_export/doc.zig");
pub const response = @import("core/response.zig");
pub const response_content = @import("core/response_content.zig");
pub const response_status = @import("core/response_status.zig");
pub const header_text = @import("core/header_text.zig");
pub const metrics = @import("utils/metrics.zig");
pub const store = @import("storage/store.zig");
pub const workspace_store = @import("storage/workspace_store.zig");
pub const lines = @import("utils/lines.zig");
pub const text_layout = @import("core/text_layout.zig");
pub const response_search = @import("core/response_search.zig");
pub const brackets = @import("utils/brackets.zig");
pub const search = @import("utils/search.zig");
pub const log = @import("core/log.zig");
pub const highlight = @import("utils/highlight.zig");
pub const collection_store = @import("storage/collection_store.zig");
pub const transport = @import("network/transport.zig");
pub const header_check = @import("network/header_check.zig");
pub const prepare = @import("network/prepare.zig");
pub const upload_info = @import("app/upload_info.zig");
pub const regex = @import("utils/regex.zig");
pub const code_font = @import("ui/code_font.zig");
pub const folding = @import("ui/folding.zig");
pub const response_prepare = @import("app/response_prepare.zig");
pub const http_client = @import("network/http_client.zig");

test {
    std.testing.refAllDecls(@This());
    if (builtin.is_test) _ = @import("import_export/postman_tests.zig");
}
