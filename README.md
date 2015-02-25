# openwebrtc-ios-test

This repository contains test code to exercise OpenWebRTC on iOS. In general, the code found here is full of hacky tests and, at times, not a shining example of how to do things right.

## Setting up

1. Tell the Xcode project about your `cerbero/dist` directory by editing the `CERBERO_DIST` custom setting in the Xcode project settings. (The default is `$(HOME)/cerbero/dist`.)

The library and header search paths should be picked up automatically for arm64 and armv7 iOS targets — from Cerbero's `dist/arm64` and `dist/armv7` as appropriate. We're not using iOS universal binaries cause they're inconvenient during a development cycle.
