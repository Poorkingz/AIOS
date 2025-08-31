
AIOS_Dev — LoadOnDemand developer tools for AIOS

Install:
1) Extract the 'AIOS_Dev' folder into Interface/AddOns/
2) Ensure your main AIOS.toc includes: modules/AIOS_DevMode.lua (the ON/OFF switch)
3) Do NOT include any of these module files in the main AIOS.toc — they live here.

Usage:
- /aiosdev on      -> loads AIOS_Dev now
- /aiosdev off     -> disables DevMode (reload to fully unload)
- /aiosdev status  -> shows loaded/enabled state
- /aiosdev diag    -> writes diagnostics to /aiosdbg

Tools:
- /aiosdbg         -> open debug log viewer
- /aiosctl         -> dev controls (dbg on/off, lvl, export, clear, test)
- /aiostest        -> run QA smoke tests
- /aiosbench       -> micro benchmarks
- /aiostrace       -> trace AIOS signals (on <EV>|* | off | list | diag | selftest)
- /aiosts clock|seconds -> timestamp format
- /aiostraceprobe  -> emit TRACE_DEMO test signals
