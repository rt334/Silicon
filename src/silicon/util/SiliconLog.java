package silicon.util;

import arc.util.Log;
import silicon.Vars;

public class SiliconLog extends Log {
    private static final Object[] empty = {};

    public static void info(String text, Object... args) {
        log(LogLevel.info, "[" + Vars.name + "] " + text, args);
    }

    public static void info(Object object) {
        info(String.valueOf(object), empty);
    }

    public static void warn(String text, Object... args) {
        log(LogLevel.warn, "[" + Vars.name + "] " + text, args);
    }

    /**
     * 错误级别。**显式转发给 arc 的 {@code Log.err(String, Throwable)}**，而不是走
     * {@code log(level, text, args)} —— 后者只做文本格式化，Throwable 会被压成
     * {@code e.toString()} 而丢掉堆栈；排查线上问题时那一行堆栈往往就是全部线索。
     */
    public static void err(String text, Throwable t) {
        Log.err("[" + Vars.name + "] " + text, t);
    }
}
