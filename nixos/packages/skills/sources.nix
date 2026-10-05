# Pinned upstream sources of the agent skill packs (agentos.skills).
#
# Every pack is fetched by commit and content hash, so the skills an agent
# sees are reproducible and reviewable. To update one, change `rev`, set
# `hash = lib.fakeHash`, build, and copy the hash from the error.
{ fetchFromGitHub }:

{
  img2threejs = fetchFromGitHub {
    owner = "img2threejs";
    repo = "img2threejs";
    rev = "fe2d0d2d1263cd8203f486bf6f4526110da42f9c";
    hash = "sha256-LMNa8RmMoOSo0fiIf/tVzHU5x2mceQvGSegrHjcOrQ8=";
  };

  reticle = fetchFromGitHub {
    owner = "reticlehq";
    repo = "reticle";
    rev = "9b6e2a201f2c0183693f9caff87c61d5b13a19f5";
    hash = "sha256-Rn6RVzt9TGVbj77LEzM/7XC1gRXom8pUXPULjstt400=";
  };

  chisle = fetchFromGitHub {
    owner = "JayPokale";
    repo = "Chisle";
    rev = "27767d663931c558827ca5c44ea126781d98041e";
    hash = "sha256-nP4fRrx6ABFApKaLn3KFZEuaRz0IBsfRoolMFW7uSFs=";
  };

  ui-skills = fetchFromGitHub {
    owner = "ibelick";
    repo = "ui-skills";
    rev = "e4c80664b61b0006a03bb6ba8339d6d82777b690";
    hash = "sha256-IxGxc+/XEU3fRPSGLL4UkPwSeq7BIZ5ro8YgMW1iQ4U=";
  };

  ouroboros = fetchFromGitHub {
    owner = "Q00";
    repo = "ouroboros";
    rev = "1b113faf17edf86e8899dc484e90d06ffb35b0e5";
    hash = "sha256-soQlYJKbD545k5ofiMaQTceZzwNgiuu+7ZjuSCmcNDg=";
  };

  fwc-swiftui-skills = fetchFromGitHub {
    owner = "FloWritesCode";
    repo = "fwc-swiftui-skills";
    rev = "69f9574707436a22400c2e13e01858ea1f335c40";
    hash = "sha256-zuPSwXF1s9Nafp8Sccd2Bk0WiNFPCluY0TzRIZKmke0=";
  };

  caliper = fetchFromGitHub {
    owner = "edonadei";
    repo = "caliper";
    rev = "f3f03559731d461dbade9a6f2c3cc2d37534f2e8";
    hash = "sha256-mrJ74MaSCI0uRHCtLEqWlOgRin8/m+GvaJ5ro8w7mNU=";
  };

  anti-slop = fetchFromGitHub {
    owner = "dmmulroy";
    repo = "anti-slop";
    rev = "c44ef22ca116d0ba62a3ff663a0bd13a3f3fa40b";
    hash = "sha256-LfkM/9AZBaZV67MsqrVgiKSPJk8AjrErFdzIBApz69E=";
  };

  karpathy-guidelines = fetchFromGitHub {
    owner = "multica-ai";
    repo = "andrej-karpathy-skills";
    rev = "2c606141936f1eeef17fa3043a72095b4765b9c2";
    hash = "sha256-4z/wRdYH7UXRzF8RJU0sw8xbpx0BW/7CBv5sVEC2knY=";
  };

  karpathy-claude-skills = fetchFromGitHub {
    owner = "benfngu";
    repo = "karpathy-claude-skills";
    rev = "f01a9330440f06b3c9ddcfdbec71c726307ebd5b";
    hash = "sha256-gtL3mbf6+clvQMsMPFFpsq2Wc6GvoS/6stfr3M2SsDU=";
  };

  # Community collections (opt-in packs, see docs/skills.md)

  composio-awesome-claude-skills = fetchFromGitHub {
    owner = "ComposioHQ";
    repo = "awesome-claude-skills";
    rev = "be2a406907dbc61b73e6827ded415c96139d13a2";
    hash = "sha256-tJBtcbfWw9jvlx8kbh4tv5kpzXT2iuA26S16DZU6tdU=";
  };

  superpowers = fetchFromGitHub {
    owner = "obra";
    repo = "superpowers";
    rev = "8ca22dba9a94f28898bbce59f2537ff4d87c747d";
    hash = "sha256-BWPiXoXV+jePP+wn/Z+Af4iehIL7oei00plaWaTzq8s=";
  };

  anthropic-skills = fetchFromGitHub {
    owner = "anthropics";
    repo = "skills";
    rev = "8a1541c4a3ffa5a20a5a91de0dcf3f0bab1d1ef4";
    hash = "sha256-PRBkTEGNwT73EFCvuTprzIBGiG+UGSYiaCkY7Ji13us=";
  };

  mattpocock-skills = fetchFromGitHub {
    owner = "mattpocock";
    repo = "skills";
    rev = "24fe0ef7737efae15c87225755e9f6f5965e4888";
    hash = "sha256-/mAmj7QFdyOWhLmy3Rt2/Hfsh5qwirTRax7hmQffFdo=";
  };

  gstack = fetchFromGitHub {
    owner = "garrytan";
    repo = "gstack";
    rev = "55fbe77195b1c2b4387a7138cb367487205fa409";
    hash = "sha256-OyiQBStxz7/pWgnfRCg+enzL+ycwuNklxUr9Rxdnvkc=";
  };

  ui-ux-pro-max = fetchFromGitHub {
    owner = "nextlevelbuilder";
    repo = "ui-ux-pro-max-skill";
    rev = "477bcb28c9812b385cb51a4605ddf30d7b2266e2";
    hash = "sha256-vh9T4eqvexVzF9NqsASvTHrA43JSUkuEVQU17mERMSU=";
  };

  everything-claude-code = fetchFromGitHub {
    owner = "affaan-m";
    repo = "everything-claude-code";
    rev = "ef648e01899ba3e8dc6371642deaaf64b4477775";
    hash = "sha256-A5UmMgKunPwev/WQsN1cdWU90rxI6qLw06/tUtLGOWc=";
  };

  scientific-skills = fetchFromGitHub {
    owner = "K-Dense-AI";
    repo = "scientific-agent-skills";
    rev = "154988403bb5a18e9d3c0ce4e6d5e2e4b184a298";
    hash = "sha256-kjIjFPOMmiC8O1sEijCsR4omgrrkK8huC5f8EHwkkTo=";
  };

  caveman = fetchFromGitHub {
    owner = "JuliusBrussee";
    repo = "caveman";
    rev = "6571943370f7c9d4de1946481177ee7b306cd8e8";
    hash = "sha256-ZkDCcKjrh5VybFBg28A29hlNz+b0Bi/wKbTzZ22diKY=";
  };

  cursor-plugins = fetchFromGitHub {
    owner = "cursor";
    repo = "plugins";
    rev = "e43c7ee26e0038c6c1fa8380dd34ce86ff94cb2a";
    hash = "sha256-AZlQa2TypJr8W8Y6YDwRc65LWK+CEbrTiM2BRYU+Rok=";
  };

  vibe-security = fetchFromGitHub {
    owner = "raroque";
    repo = "vibe-security-skill";
    rev = "850938f20f6915e7c3688d85c0a838f7909c87bb";
    hash = "sha256-gx1olMP1wFrcR1fZu4pFqVLwp7AYhoUKy0/VLeLi0vk=";
  };

  no-ai-slop = fetchFromGitHub {
    owner = "petergyang";
    repo = "no-ai-slop";
    rev = "000650b156983f5159695b441477f4e63b25dc85";
    hash = "sha256-l/BZaNnPvFKTUN7jVs5p5aEtRvOUbwMElu37cnP+k8E=";
  };

  ponytail = fetchFromGitHub {
    owner = "DietrichGebert";
    repo = "ponytail";
    rev = "e15862bb04d04285233a164460ced063941d9ef5";
    hash = "sha256-MwdDEgZGUQV4J1Yqslik+CUWDZxj9qaAG8EAbiQgxG8=";
  };

  hyperframes = fetchFromGitHub {
    owner = "heygen-com";
    repo = "hyperframes";
    rev = "db12b3e022ef343d1d2318e9722f7668a1efc2c7";
    hash = "sha256-159NhxSFuczgyjD/wHevh7WCDEsLld2lOojhobOiMLI=";
  };

  impeccable = fetchFromGitHub {
    owner = "pbakaus";
    repo = "impeccable";
    rev = "ece38d9904b8a619b3f77cab476eacad09c4fb11";
    hash = "sha256-JPGkMvspzXvZJlvyrXbB37uCmZ5AmDpDUdq4ZsmPlKo=";
  };

  taste-skill = fetchFromGitHub {
    owner = "Leonxlnx";
    repo = "taste-skill";
    rev = "ce26fc25c0e5e8cab638f883de62d9a86ee5e45b";
    hash = "sha256-1X7XrXi2mivzmrqa9+zkIHs0uFUoXaqhOXQIHqK8lV0=";
  };

  unlazy = fetchFromGitHub {
    owner = "Leonxlnx";
    repo = "unlazy";
    rev = "16671491f6679ad9378f52604d3bc2415b4120c7";
    hash = "sha256-vXsXf8lN8wQW/aSittxdFjglMMB4Yf29N0bpoJJ56bY=";
  };

  ai-job-search = fetchFromGitHub {
    owner = "MadsLorentzen";
    repo = "ai-job-search";
    rev = "52f84e0f823780362964f270200463370ef3b3e7";
    hash = "sha256-oIXw6h9l9XyM9S/cXokDnG7D0FnRWic2mImRMozIYdw=";
  };

  agent-reach = fetchFromGitHub {
    owner = "Panniantong";
    repo = "Agent-Reach";
    rev = "a19a171fa980a0785849596492e0af4db800c82f";
    hash = "sha256-DVGnyj7kZVKT68BERuuX4oGiMqxqstj2u6J3XpuZ1Gw=";
  };

  open-design = fetchFromGitHub {
    owner = "nexu-io";
    repo = "open-design";
    rev = "53231d40b778d88eba23f35547bf99485d3ae9fc";
    hash = "sha256-FFgtdh/EcFvQWD7F7tv5jz0U1o4IjXBjw6ED/aHRIu0=";
  };
}
