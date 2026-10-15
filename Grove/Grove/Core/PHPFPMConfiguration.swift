import Foundation

public enum PHPFPMConfiguration {
    public static func pool(socket: URL, pid: URL, workers: Int, onDemand: Bool = false) throws -> String {
        guard (2...32).contains(workers), socket.path.utf8.count < 104 else { throw GroveError.message("PHP-FPM needs 2–32 workers and a valid short Unix socket path.") }
        for value in [socket.path, pid.path] { guard value.range(of: #"^[A-Za-z0-9/_-]+(?:\.[A-Za-z0-9]+)?$"#, options: .regularExpression) != nil else { throw GroveError.message("Invalid PHP-FPM runtime path.") } }
        let processManagement = onDemand ? "pm = ondemand\npm.max_children = \(workers)\npm.process_idle_timeout = 10s" : "pm = dynamic\npm.max_children = \(workers)\npm.start_servers = 2\npm.min_spare_servers = 2\npm.max_spare_servers = \(max(2, min(workers, 4)))"
        return """
        [global]
        daemonize = no
        error_log = /dev/stderr
        log_level = notice
        pid = \(pid.path)
        process_control_timeout = 3s
        [grove]
        listen = \(socket.path)
        listen.mode = 0600
        \(processManagement)
        pm.max_requests = 500
        catch_workers_output = yes
        decorate_workers_output = no
        clear_env = no
        security.limit_extensions = .php
        chdir = /
        php_admin_flag[log_errors] = on
        php_admin_value[error_log] = /dev/stderr
        """
    }
}
