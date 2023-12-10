const std = @import("std");

const Response = std.http.Server.Response;

pub fn notFound(response: *Response) !void {
    response.status = .not_found;
    try response.do();
}

pub fn file(response: *Response, mimeType: []const u8, contents: []const u8) !void {
    response.status = .ok;
    response.transfer_encoding = .chunked;

    try response.headers.append("content-type", mimeType);

    try response.do();
    try response.writeAll(contents);
    try response.finish();
}

pub fn json(response: *Response, contents: []const u8) !void {
    return file(response, "application/json", contents);
}
