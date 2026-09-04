"""Build small editable ComfyUI UI workflows, using only native nodes."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "comfy" / "workflows"


class Graph:
    def __init__(self):
        self.nodes = []
        self.links = []

    def node(self, kind, widgets, inputs=(), outputs=(), pos=(0, 0), title=None):
        node = {"id": len(self.nodes) + 1, "type": kind, "pos": list(pos), "size": [315, 220],
                "flags": {}, "order": len(self.nodes), "mode": 0,
                "inputs": [{"name": name, "type": typ, "link": None} for name, typ in inputs],
                "outputs": [{"name": typ, "type": typ, "links": []} for typ in outputs],
                "properties": {"Node name for S&R": kind}, "widgets_values": widgets}
        if title:
            node["title"] = title
        self.nodes.append(node)
        return node

    def connect(self, source, slot, dest, input_slot):
        link_id = len(self.links) + 1
        self.links.append([link_id, source["id"], slot, dest["id"], input_slot, source["outputs"][slot]["type"]])
        source["outputs"][slot]["links"].append(link_id)
        dest["inputs"][input_slot]["link"] = link_id

    def write(self, filename):
        ROOT.mkdir(parents=True, exist_ok=True)
        value = {"last_node_id": len(self.nodes), "last_link_id": len(self.links), "nodes": self.nodes,
                 "links": self.links, "groups": [], "config": {}, "extra": {}, "version": 0.4}
        (ROOT / filename).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def generate(video):
    g = Graph()
    if video:
        model = g.node("UNETLoader", ["wan2.1_t2v_1.3B_fp16.safetensors", "default"], outputs=["MODEL"])
        clip = g.node("CLIPLoader", ["umt5_xxl_fp8_e4m3fn_scaled.safetensors", "wan", "default"], outputs=["CLIP"], pos=(0, 260))
        vae = g.node("VAELoader", ["wan_2.1_vae.safetensors"], outputs=["VAE"], pos=(0, 520))
        sampling = g.node("ModelSamplingSD3", [8.0], [("model", "MODEL")], ["MODEL"], pos=(360, 0))
        g.connect(model, 0, sampling, 0)
        latent = g.node("EmptyHunyuanLatentVideo", [832, 480, 33, 1], outputs=["LATENT"], pos=(360, 770))
        clip_slot, vae_slot = 0, 0
    else:
        model = g.node("CheckpointLoaderSimple", ["v1-5-pruned-emaonly-fp16.safetensors"], outputs=["MODEL", "CLIP", "VAE"])
        clip = vae = sampling = model
        clip_slot, vae_slot = 1, 2
        latent = g.node("EmptyLatentImage", [512, 512, 1], outputs=["LATENT"], pos=(360, 770))
    positive = g.node("CLIPTextEncode", ["A small orange cat walking through a sunny garden, cinematic natural light"], [("clip", "CLIP")], ["CONDITIONING"], pos=(360, 260), title="Positive prompt")
    negative = g.node("CLIPTextEncode", ["blurry, distorted, low quality, text, watermark"], [("clip", "CLIP")], ["CONDITIONING"], pos=(360, 520), title="Negative prompt")
    sampler = g.node("KSampler", [42, "fixed", 20, 6.0 if video else 7.0, "uni_pc" if video else "euler", "simple" if video else "normal", 1.0],
                     [("model", "MODEL"), ("positive", "CONDITIONING"), ("negative", "CONDITIONING"), ("latent_image", "LATENT")], ["LATENT"], pos=(720, 260))
    decode = g.node("VAEDecode", [], [("samples", "LATENT"), ("vae", "VAE")], ["IMAGE"], pos=(1080, 260))
    save = g.node("SaveAnimatedWEBP" if video else "SaveImage",
                  ["video/wan21", 16.0, False, 90, "default"] if video else ["image/sd15"],
                  [("images", "IMAGE")], pos=(1440, 260))
    for dest in (positive, negative):
        g.connect(clip, clip_slot, dest, 0)
    for src, slot, target_slot in ((sampling, 0, 0), (positive, 0, 1), (negative, 0, 2), (latent, 0, 3)):
        g.connect(src, slot, sampler, target_slot)
    g.connect(sampler, 0, decode, 0)
    g.connect(vae, vae_slot, decode, 1)
    g.connect(decode, 0, save, 0)
    g.write("video_default.json" if video else "image_default.json")


if __name__ == "__main__":
    generate(True)
    generate(False)
