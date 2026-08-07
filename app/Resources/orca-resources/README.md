This directory ships in the app bundle as the engine's resources path.

It is empty by design. `sp_engine_create` requires a resources directory to
exist, but nothing in the sliced path reads from it: profiles arrive already
resolved from a saved desktop project, so there is no vendor profile tree to
carry. If a future feature needs a resource from OrcaSlicer's own tree, it goes
here and this note goes away.
