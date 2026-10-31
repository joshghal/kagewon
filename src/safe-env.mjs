// Imported first by proxy.mjs. Some libraries print every destination host name to stderr when DEBUG is set, and the helper's
// output ends up in a log file that must never contain the sites you visit. They read the variable when they load,
// so it has to be gone before they do.
delete process.env.DEBUG;
delete process.env.NODE_DEBUG;
