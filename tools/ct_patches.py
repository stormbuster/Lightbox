"""coremltools fixes needed for these models (import before converting)."""
import numpy as np
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as _ops

_orig_cast = _ops._cast


def _cast(context, node, dtype, dtype_name):     # traced shape math yields 1-element arrays: take the scalar
    x = _ops._get_inputs(context, node, expected=1)[0]
    if x.val is not None and getattr(x.val, "shape", ()) not in ((), None) and np.size(x.val) == 1:
        context.add(mb.const(val=dtype(np.asarray(x.val).item()), name=node.name))
        return
    _orig_cast(context, node, dtype, dtype_name)


_ops._cast = _cast
