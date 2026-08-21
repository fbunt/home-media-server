# Butane

Compile the Ignition config with:

    butane --pretty --strict media-server.bu -o media-server.ign

`*.ign` files are gitignored: compiled Ignition configs can embed the
SSH keys and other secrets you substituted in, so they must never be committed.
