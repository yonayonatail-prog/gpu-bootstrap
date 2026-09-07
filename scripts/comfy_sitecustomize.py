"""Small runtime compatibility shims for the pinned ComfyUI environment.

Python imports ``sitecustomize`` during startup.  Keep this module deliberately
narrow: it only adapts an optional progress-bar keyword used by the pinned
TRELLIS2 node when the installed Hugging Face client predates that API.
"""

import inspect


try:
    import huggingface_hub
except ImportError:
    # The module can be imported while pip is creating the environment.
    pass
else:
    _hf_hub_download = huggingface_hub.hf_hub_download
    if "tqdm_class" not in inspect.signature(_hf_hub_download).parameters:

        def _compatible_hf_hub_download(*args, **kwargs):
            # TRELLIS2 uses this only to route progress into the ComfyUI UI.
            # Older supported Hub clients download correctly without it.
            kwargs.pop("tqdm_class", None)
            return _hf_hub_download(*args, **kwargs)

        huggingface_hub.hf_hub_download = _compatible_hf_hub_download
