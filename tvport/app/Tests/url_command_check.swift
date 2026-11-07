// Checks TVPortURLCommand.parse without the UI. Run from tvport/app:
//   swiftc -parse-as-library -o /tmp/url_command_check Sources/TVPortURLCommand.swift Tests/url_command_check.swift && /tmp/url_command_check
// Exits non-zero on any failure.
import Foundation

@main enum UTCheck {
static func main() {
var failures = 0
func check(_ name: String, _ url: String, _ expected: Result<TVPortURLCommand, TVPortURLCommand.Reason>) {
    let got = TVPortURLCommand.parse(URL(string: url)!)
    if got != expected { failures += 1; print("FAIL \(name): \(url) -> \(got)") } else { print("ok   \(name)") }
}
let id = "0100ABCDEF123456"
check("build default install", "tvport://build?title=\(id)", .success(.build(titleID: id, install: true)))
check("install=1", "tvport://build?title=\(id)&install=1", .success(.build(titleID: id, install: true)))
check("install=0", "tvport://build?title=\(id)&install=0", .success(.build(titleID: id, install: false)))
check("lowercase hex", "tvport://build?title=\(id.lowercased())", .success(.build(titleID: id, install: true)))
check("trailing slash", "tvport://build/?title=\(id)", .success(.build(titleID: id, install: true)))
check("extra query ignored", "tvport://build?foo=bar&title=\(id)&x=1", .success(.build(titleID: id, install: true)))
check("short title", "tvport://build?title=0100ABCDEF12345", .failure(.malformedTitle))
check("long title", "tvport://build?title=\(id)0", .failure(.malformedTitle))
check("non-hex title", "tvport://build?title=0100ABCDEF12345G", .failure(.malformedTitle))
check("missing title", "tvport://build?install=1", .failure(.malformedTitle))
check("empty title", "tvport://build?title=", .failure(.malformedTitle))
check("duplicate title", "tvport://build?title=\(id)&title=\(id)", .failure(.malformedTitle))
check("unknown host", "tvport://remove?title=\(id)", .failure(.unsupported))
check("extra path", "tvport://build/x?title=\(id)", .failure(.unsupported))
check("no host", "tvport:///build?title=\(id)", .failure(.unsupported))
check("wrong scheme", "https://build?title=\(id)", .failure(.unsupported))
check("install=2", "tvport://build?title=\(id)&install=2", .failure(.malformedInstall))
check("install=true", "tvport://build?title=\(id)&install=true", .failure(.malformedInstall))
check("install empty", "tvport://build?title=\(id)&install=", .failure(.malformedInstall))
check("install twice", "tvport://build?title=\(id)&install=1&install=0", .failure(.malformedInstall))
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all passed")
}
}
