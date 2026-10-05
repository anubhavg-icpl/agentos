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
}
