import os
import re

file_path = "/Users/mschmidbartl/Desktop/Vynce/vynce/pbjs/modules/JSWindow.pb"

with open(file_path, "r") as f:
    content = f.read()

# 1. Fix MacOSFrameDidChange map access
resize_pattern = r"\*JSWindow\.JSWIndow = JSWindows\(Str\(MacOSResizeStates\(\)\\Window\\Window\)\)"
resize_replacement = r"""LockMutex(JSWindowMutex)
          If FindMapElement(JSWindows(), Str(MacOSResizeStates()\\Window\\Window))
            *JSWindow.JSWindow = @JSWindows()
          Else
            UnlockMutex(JSWindowMutex)
            UnlockMutex(MacOSResizeMonitorMutex)
            ProcedureReturn
          EndIf
          UnlockMutex(JSWindowMutex)"""
content = re.sub(resize_pattern, resize_replacement, content)

# 2. Fix RegisterManageWindow map access
register_pattern = r"\*JSWindow\.JSWindow = JSWindows\(Str\(window\)\)"
register_replacement = r"""LockMutex(JSWindowMutex)
      If FindMapElement(JSWindows(), Str(window))
        *JSWindow.JSWindow = @JSWindows()
      Else
        UnlockMutex(JSWindowMutex)
        ProcedureReturn
      EndIf
      UnlockMutex(JSWindowMutex)"""
content = re.sub(register_pattern, register_replacement, content)

# 3. Fix HandleEvent UpdateWebViewScale map access
update_scale_pattern = r"(UpdateWebViewScale\()JSWindows\(Str\(\*Window\\Window\)\)"
update_scale_replacement = r"\1*JSWindow" # We already have *JSWindow in HandleEvent
content = re.sub(update_scale_pattern, update_scale_replacement, content)

# 4. Fix JSReadyState map access (if any left)
ready_pattern = r"(If Not )JSWindows\(Str\(window\)\)\\Ready"
ready_replacement = r"LockMutex(JSWindowMutex)\n      Protected isReady = #False\n      If FindMapElement(JSWindows(), Str(window))\n        isReady = JSWindows()\\Ready\n      EndIf\n      UnlockMutex(JSWindowMutex)\n      If Not isReady"
content = re.sub(ready_pattern, ready_replacement, content)

with open(file_path, "w") as f:
    f.write(content)

print("Applied final replacements correctly")
