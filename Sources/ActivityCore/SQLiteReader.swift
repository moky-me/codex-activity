import Foundation
import CSQLite

public enum DBValue: Equatable {
    case text(String), integer(Int64), real(Double), null
    public var string:String? { if case .text(let value)=self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
    public var number:Double? {
        switch self { case .integer(let n):return Double(n); case .real(let n):return n; default:return nil }
    }
}
public struct DatabaseError: Error, LocalizedError {
    public var message:String
    public var errorDescription:String? { message }
}

/// Never creates a database, changes its journal mode, or mutates the user's data.
public final class SQLiteReader {
    private var handle:OpaquePointer?
    public init(url:URL) throws {
        let code=sqlite3_open_v2(url.path,&handle,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)
        guard code==SQLITE_OK else {
            let message=handle.map { String(cString:sqlite3_errmsg($0)) } ?? "Database unavailable"
            if let handle { sqlite3_close(handle) }; handle=nil
            throw DatabaseError(message:message)
        }
        sqlite3_busy_timeout(handle,300)
    }
    deinit { if let handle { sqlite3_close(handle) } }
    public func query(_ sql:String,_ values:[DBValue]=[]) throws -> [[String:DBValue]] {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil)==SQLITE_OK, let statement else {
            throw DatabaseError(message:String(cString:sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement)==1 else { throw DatabaseError(message:"Запись в данные Codex запрещена") }
        for (index,value) in values.enumerated() {
            let position=Int32(index+1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement,position,text,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))
            case .integer(let n): sqlite3_bind_int64(statement,position,n)
            case .real(let n): sqlite3_bind_double(statement,position,n)
            case .null: sqlite3_bind_null(statement,position)
            }
        }
        var result:[[String:DBValue]]=[]
        while true {
            let code=sqlite3_step(statement)
            if code==SQLITE_DONE { break }
            guard code==SQLITE_ROW else { throw DatabaseError(message:String(cString:sqlite3_errmsg(handle))) }
            var row:[String:DBValue]=[:]
            for index in 0..<sqlite3_column_count(statement) {
                let name=String(cString:sqlite3_column_name(statement,index))
                switch sqlite3_column_type(statement,index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement,index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement,index))
                case SQLITE_TEXT: row[name] = .text(String(cString:sqlite3_column_text(statement,index)))
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }
}
