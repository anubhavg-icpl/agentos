# AgentOS Editors Module
# Pre-configured editors with agent-friendly defaults
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.agentos.editors;
in
{
  options.agentos.editors = {
    enable = lib.mkEnableOption "AgentOS pre-configured editors";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = avail (with pkgs; [
      neovim
      helix
      micro
      vim
      tree-sitter
    ]);

    # Neovim with default config
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      configure = {
        packages.myVimPackage = with pkgs.vimPlugins; {
          start = [
            nvim-lspconfig
            nvim-treesitter
            telescope-nvim
            plenary-nvim
            which-key-nvim
            lualine-nvim
            nvim-cmp
            cmp-nvim-lsp
            luasnip
            vim-fugitive
            gitsigns-nvim
            nord-nvim
          ];
        };
      };
    };
  };
}
