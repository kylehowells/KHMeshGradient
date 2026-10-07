"""LLDB-only geometry probe for the verified iOS 26.5 Simulator RenderBox.

Launch the example with --probe-swiftui-geometry and --wait-for-debugger. Stop
at UIApplicationMain and disable stdout buffering before continuing. In LLDB:

  command script import Scripts/probe_renderbox_geometry_lldb.py
  script probe_renderbox_geometry_lldb.install(lldb.debugger, STDOUT_PATH, OUTPUT_PATH)
  continue

Paths are supplied by the caller; output contains no pointers or binary code.
This reads private framework state for research and is never linked into the app.
Do not apply offsets to another framework build. See the experiment report.
"""
import json
from pathlib import Path
import struct

import lldb

_records = []
_entries = {}
_stdout = None
_output = None
_exit_installed = False
_case_label = None
_maximum_observations = None
# Mach-O UUID of the framework whose instructions/ABI were inspected.
_verified_uuid = '208CB2C6-A896-3BC7-9742-AB21E55B5B4C'


def _register(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def _read(process, address, size):
    error = lldb.SBError()
    data = process.ReadMemory(address, size, error)
    if not error.Success():
        raise RuntimeError(str(error))
    return data


def entry(frame, location, internal_dict):
    global _exit_installed
    try:
        process = frame.GetThread().GetProcess()
        target = process.GetTarget()
        if not _exit_installed:
            module = location.GetAddress().GetModule()
            if module.GetUUIDString().upper() != _verified_uuid:
                raise RuntimeError('Unverified RenderBox UUID: ' + module.GetUUIDString())
            symbol = location.GetAddress().GetSymbol()
            base = symbol.GetStartAddress().GetLoadAddress(target)
            end = target.BreakpointCreateByAddress(base + 744)
            end.SetScriptCallbackFunction(__name__ + '.finish')
            _exit_installed = True
        lines = _stdout.read_text().splitlines() if _case_label is None else []
        case = _case_label or next((line for line in reversed(lines) if line.startswith('GEOMETRY_PROBE_CASE ')), None)
        if case is None:
            raise RuntimeError('No flushed case marker; disable stdout buffering at UIApplicationMain')
        _entries[frame.GetThread().GetThreadID()] = {
            'globals': _register(frame, 'x2'), 'case': case,
            'meshTypeFlags': _read(process, _register(frame, 'x0') + 0x2b, 1)[0],
        }
    except Exception as error:
        print('GEOMETRY_PROBE_ERROR', error)
        return True
    return False


def finish(frame, location, internal_dict):
    try:
        process = frame.GetThread().GetProcess()
        record = _entries.pop(frame.GetThread().GetThreadID())
        globals_data = _read(process, record.pop('globals'), 24)
        depth = struct.unpack_from('<H', globals_data, 16)[0]
        if not 0 <= depth <= 7:
            raise RuntimeError('Unexpected subdivision depth: ' + str(depth))
        record.update(depth=depth, subdivisions=1 << depth, patchCount=_register(frame, 'x20'))
        stack = _read(process, _register(frame, 'sp') + 0x20, 16)
        record['maxSecondDifferenceXY'] = list(struct.unpack_from('<ff', stack, 0))
        record['transformScale'] = struct.unpack_from('<f', stack, 12)[0]
        _records.append(record)
        _output.write_text(json.dumps({'frameworkUUID': _verified_uuid, 'observations': _records}, indent=2) + '\n')
        print('GEOMETRY_OBSERVED', json.dumps(record), flush=True)
        return ('GEOMETRY_PROBE_CASE 9 ' in record['case'] or
                (_maximum_observations is not None and len(_records) >= _maximum_observations))
    except Exception as error:
        print('GEOMETRY_PROBE_ERROR', error)
        return True


def install(debugger, stdout_path, output_path, case_label=None, maximum_observations=None):
    global _stdout, _output, _case_label, _maximum_observations
    _stdout = Path(stdout_path)
    _output = Path(output_path)
    _case_label = case_label
    _maximum_observations = maximum_observations
    _output.parent.mkdir(parents=True, exist_ok=True)
    target = debugger.GetSelectedTarget()
    breakpoint = target.BreakpointCreateByRegex(r'^RB::Fill::MeshGradient::make_buffers\(')
    breakpoint.SetScriptCallbackFunction(__name__ + '.entry')
    print('GEOMETRY_PROBE_INSTALLED; deferred framework loading is supported')
