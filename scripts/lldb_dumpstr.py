import lldb, re

PATS = ['entitle', 'com.apple.', 'iapd', 'iap2d', 'Mac', 'macOS', 'platform', 'Launched', 'available']

def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    for m in target.module_iter():
        name = m.GetFileSpec().GetFilename()
        if name not in ('IAP', 'ExternalAccessory', 'CoreAccessories', 'IAPAuthentication'):
            continue
        print("### module", name, m.GetFileSpec().GetDirectory())
        for sec in m.section_iter():
            for i in range(sec.GetNumSubSections()):
                sub = sec.GetSubSectionAtIndex(i)
                if sub.GetName() not in ('__cstring', '__oslogstring', '__objc_methname', '__objc_classname'):
                    continue
                addr = sub.GetLoadAddress(target)
                size = sub.GetByteSize()
                err = lldb.SBError()
                data = process.ReadMemory(addr, size, err)
                if not err.Success():
                    print("  read fail", sub.GetName(), err)
                    continue
                seen = set()
                for s in re.findall(rb'[\x20-\x7e]{4,}', data):
                    ss = s.decode()
                    if ss in seen:
                        continue
                    seen.add(ss)
                    if sub.GetName() in ('__objc_methname', '__objc_classname') or any(p in ss for p in PATS):
                        print("  [%s] %s" % (sub.GetName(), ss))
