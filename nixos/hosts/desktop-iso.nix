# The live ISO with the desktop: boots straight into the session so people
# can try AgentOS, and `agentos-install --desktop` installs it from there.
# Separate from the minimal ISO because the IDEs make it several GB larger.
{ ... }:

{
  # The live user has an empty password, so the lock screen accepts it
  agentos.desktop.autologin = {
    enable = true;
    user = "agentos-live";
  };
}
