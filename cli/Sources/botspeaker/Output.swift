import Foundation

enum Output {
    static func json(_ value: Any) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            print("{}")
            return
        }
        print(text)
    }

    static func fail(_ failure: ControlClient.Failure, json: Bool) -> Never {
        if json {
            Output.json(["ok": false, "error": ["code": failure.code, "message": failure.message]])
        } else {
            FileHandle.standardError.write(Data("error: \(failure.message)\n".utf8))
        }
        exit(failure.exitCode)
    }

    static func fail(_ error: Error, json: Bool) -> Never {
        if let failure = error as? ControlClient.Failure {
            fail(failure, json: json)
        }
        fail(ControlClient.Failure(exitCode: 1, code: "error", message: error.localizedDescription), json: json)
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let flag as Bool: return flag ? "yes" : "no"
        case let number as NSNumber: return number.stringValue
        case nil, is NSNull: return "-"
        default: return "\(value!)"
        }
    }

    static func table(_ rows: [[String]]) {
        guard let first = rows.first else { return }
        var widths = Array(repeating: 0, count: first.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        for row in rows {
            let line = row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            print(line)
        }
    }
}
