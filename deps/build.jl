if Sys.islinux()
    max_watches=parse(Int, chomp(read(`cat /proc/sys/fs/inotify/max_user_watches`, String)))
    if max_watches <= 8192 && !isfile(joinpath(@__DIR__, "user_watches"))
        default_watches = 65536
        msg = """
Revise needs to be notified by your filesystem about changes to your code. Your operating
system imposes a limit of $max_watches watched files and directories. Exceeding this limit
can cause errors, `ERROR: start_watching (File Monitor): no space left on device (ENOSPC)`.
To prevent this from happening, Revise will try to increase the number to $default_watches;
however, if you encounter the above error, consider increasing the number even further.
See the documentation for details.

Changing the number of watches is an operation that requires `sudo` privileges.
"""
        # Because output is redirected to a file, we ensure the message is printed on the screen
        run(pipeline(`echo $msg`, stdout="/dev/tty"))
        # Check whether the user has sudo privileges (will prompt for password)
        has_sudo = try success(`sudo -v`) catch err false end
        if has_sudo
            run(pipeline(`echo $default_watches`, `sudo tee -a /proc/sys/fs/inotify/max_user_watches`))
        else
            print(msg)  # dumps msg to the log file
            @warn "You lack sudo privileges, consider contacting your system administrator."
        end
    end
end
