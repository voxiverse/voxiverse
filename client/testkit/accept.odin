package testkit

// ACCEPT: the baseline the tests rewrite instead of comparing (`build audio --accept
// <scenario|all>` reruns them with -define:VX_AUDIO_ACCEPT=<scenario|all>).
ACCEPT :: #config(VX_AUDIO_ACCEPT, "")
