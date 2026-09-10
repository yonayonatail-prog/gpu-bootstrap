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


def generate_neta():
    g = Graph()
    model = g.node("CheckpointLoaderSimple", ["NetaYume-Lumina.safetensors"], outputs=["MODEL", "CLIP", "VAE"])
    lora = g.node("LoraLoaderModelOnly", ["my_lora.safetensors", 0.85], [("model", "MODEL")], ["MODEL"], pos=(360, 0), title="Your LoRA")
    positive = g.node("CLIPTextEncode", ["masterpiece, best quality, original character, soft luminous anime illustration"], [("clip", "CLIP")], ["CONDITIONING"], pos=(360, 260), title="Prompt")
    negative = g.node("CLIPTextEncode", ["low quality, blurry, bad anatomy, watermark, text"], [("clip", "CLIP")], ["CONDITIONING"], pos=(360, 520), title="Negative prompt")
    latent = g.node("EmptyLatentImage", [1024, 1024, 1], outputs=["LATENT"], pos=(360, 780))
    sampler = g.node("KSampler", [42, "fixed", 28, 6.5, "euler", "normal", 1.0], [("model", "MODEL"), ("positive", "CONDITIONING"), ("negative", "CONDITIONING"), ("latent_image", "LATENT")], ["LATENT"], pos=(720, 260))
    decode = g.node("VAEDecode", [], [("samples", "LATENT"), ("vae", "VAE")], ["IMAGE"], pos=(1080, 260))
    save = g.node("SaveImage", ["netayume_lumina"], [("images", "IMAGE")], pos=(1440, 260))
    g.connect(model, 0, lora, 0); g.connect(lora, 0, sampler, 0); g.connect(model, 1, positive, 0); g.connect(model, 1, negative, 0)
    g.connect(positive, 0, sampler, 1); g.connect(negative, 0, sampler, 2); g.connect(latent, 0, sampler, 3); g.connect(sampler, 0, decode, 0); g.connect(model, 2, decode, 1); g.connect(decode, 0, save, 0)
    g.write("netayume_lumina_lora.json")


def generate_illustrious():
    g = Graph()
    ckpt = g.node("CheckpointLoaderSimple", ["illustriousXL_v01.safetensors"], outputs=["MODEL", "CLIP", "VAE"])
    lora = g.node("LoraLoaderModelOnly", ["my_lora.safetensors", 0.85], [("model", "MODEL")], ["MODEL"], pos=(360, 0), title="Your character LoRA")
    vision = g.node("CLIPVisionLoader", ["clip_vision_h.safetensors"], outputs=["CLIP_VISION"], pos=(360, 520))
    ipmodel = g.node("IPAdapterModelLoader", ["ip-adapter-plus_sdxl_vit-h.safetensors"], outputs=["IPADAPTER"], pos=(360, 780))
    char = g.node("LoadImage", ["character_reference.png"], outputs=["IMAGE"], pos=(0, 520), title="Character / style reference")
    ip = g.node("IPAdapterAdvanced", [0.65, "linear", 0.0, 1.0, "concat", "V only"], [("model", "MODEL"), ("ipadapter", "IPADAPTER"), ("image", "IMAGE"), ("clip_vision", "CLIP_VISION")], ["MODEL"], pos=(720, 0))
    pose = g.node("LoadImage", ["pose_reference.png"], outputs=["IMAGE"], pos=(0, 900), title="OpenPose reference")
    prep = g.node("AIO_Preprocessor", ["OpenPose", 512, 512], [("image", "IMAGE")], ["IMAGE"], pos=(360, 1040), title="OpenPose")
    control = g.node("ControlNetLoader", ["controlnet-openpose-sdxl-1.0.safetensors"], outputs=["CONTROL_NET"], pos=(720, 800))
    positive = g.node("CLIPTextEncode", ["masterpiece, best quality, anime illustration, full body"], [("clip", "CLIP")], ["CONDITIONING"], pos=(1080, 0), title="Prompt")
    negative = g.node("CLIPTextEncode", ["low quality, bad anatomy, extra fingers, watermark, text"], [("clip", "CLIP")], ["CONDITIONING"], pos=(1080, 260), title="Negative prompt")
    apply = g.node("ControlNetApplyAdvanced", [0.75, 0.0, 1.0], [("positive", "CONDITIONING"), ("negative", "CONDITIONING"), ("control_net", "CONTROL_NET"), ("image", "IMAGE")], ["CONDITIONING", "CONDITIONING"], pos=(1440, 0))
    latent = g.node("EmptyLatentImage", [1024, 1024, 1], outputs=["LATENT"], pos=(1080, 520))
    sampler = g.node("KSampler", [42, "fixed", 28, 6.0, "euler", "normal", 1.0], [("model", "MODEL"), ("positive", "CONDITIONING"), ("negative", "CONDITIONING"), ("latent_image", "LATENT")], ["LATENT"], pos=(1800, 260))
    decode = g.node("VAEDecode", [], [("samples", "LATENT"), ("vae", "VAE")], ["IMAGE"], pos=(2160, 260)); save = g.node("SaveImage", ["illustrious_sdxl_controlled"], [("images", "IMAGE")], pos=(2520, 260))
    g.connect(ckpt, 0, lora, 0); g.connect(lora, 0, ip, 0); g.connect(ipmodel, 0, ip, 1); g.connect(char, 0, ip, 2); g.connect(vision, 0, ip, 3); g.connect(ckpt, 1, positive, 0); g.connect(ckpt, 1, negative, 0); g.connect(pose, 0, prep, 0); g.connect(prep, 0, apply, 3); g.connect(control, 0, apply, 2); g.connect(positive, 0, apply, 0); g.connect(negative, 0, apply, 1); g.connect(ip, 0, sampler, 0); g.connect(apply, 0, sampler, 1); g.connect(apply, 1, sampler, 2); g.connect(latent, 0, sampler, 3); g.connect(sampler, 0, decode, 0); g.connect(ckpt, 2, decode, 1); g.connect(decode, 0, save, 0)
    g.write("illustrious_sdxl_ipadapter_openpose.json")


def generate_qwen():
    g = Graph()
    image_nodes = [g.node("LoadImage", [name], outputs=["IMAGE"], pos=(0, y), title=title) for name, y, title in (("character_reference.png", 0, "Character reference"), ("clothing_style_reference.png", 300, "Clothing / style reference"), ("pose_scene_reference.png", 600, "Pose / scene reference"))]
    unet = g.node("UNETLoader", ["qwen_image_edit_2511_fp8mixed.safetensors", "default"], outputs=["MODEL"], pos=(360, 0))
    clip = g.node("CLIPLoader", ["qwen_2.5_vl_7b_fp8_scaled.safetensors", "qwen_image", "default"], outputs=["CLIP"], pos=(360, 300))
    vae = g.node("VAELoader", ["qwen_image_vae.safetensors"], outputs=["VAE"], pos=(360, 600))
    encode = g.node("TextEncodeQwenImageEditPlus", ["Keep the character identity from image 1, use the clothing and visual style from image 2, and use the pose and scene from image 3. Create a coherent finished illustration."], [("clip", "CLIP"), ("vae", "VAE"), ("image1", "IMAGE"), ("image2", "IMAGE"), ("image3", "IMAGE")], ["CONDITIONING"], pos=(720, 0), title="Instruction")
    negative = g.node("CLIPTextEncode", ["low quality, blurry, distorted, watermark, text"], [("clip", "CLIP")], ["CONDITIONING"], pos=(720, 520), title="Negative prompt")
    latent = g.node("EmptySD3LatentImage", [1024, 1024, 1], outputs=["LATENT"], pos=(1080, 760)); sampler = g.node("KSampler", [42, "fixed", 20, 4.0, "euler", "simple", 1.0], [("model", "MODEL"), ("positive", "CONDITIONING"), ("negative", "CONDITIONING"), ("latent_image", "LATENT")], ["LATENT"], pos=(1440, 260)); decode = g.node("VAEDecode", [], [("samples", "LATENT"), ("vae", "VAE")], ["IMAGE"], pos=(1800, 260)); save = g.node("SaveImage", ["qwen_image_edit_2511_multi_reference"], [("images", "IMAGE")], pos=(2160, 260))
    g.connect(unet, 0, sampler, 0); g.connect(clip, 0, encode, 0); g.connect(vae, 0, encode, 1)
    for index, image in enumerate(image_nodes, 2): g.connect(image, 0, encode, index)
    g.connect(encode, 0, sampler, 1); g.connect(clip, 0, negative, 0); g.connect(negative, 0, sampler, 2); g.connect(latent, 0, sampler, 3); g.connect(sampler, 0, decode, 0); g.connect(vae, 0, decode, 1); g.connect(decode, 0, save, 0)
    g.write("qwen_image_edit_2511_multi_reference.json")


if __name__ == "__main__":
    generate(True)
    generate(False)
    generate_neta()
    generate_illustrious()
    generate_qwen()
