#pragma once
// nativebind: bind C++ modules to Flutter. Include this in every module file.
//
//     #include <nativebind/nativebind.hpp>
//
//     class Player : public nativebind::Module {
//         NATIVEBIND_MODULE(Player)
//     public:
//         NATIVEBIND_PROP(double, volume, 0.5, .min = 0, .max = 1, .step = 0.05)
//         NATIVEBIND_READ(double, position, 0.0)
//         NATIVEBIND_SIGNAL(trackChanged, std::string)
//         NATIVEBIND_INVOKE void seek(double seconds);
//     };

#include "nativebind/codec.hpp"
#include "nativebind/list.hpp"
#include "nativebind/macros.hpp"
#include "nativebind/module.hpp"
#include "nativebind/property.hpp"
#include "nativebind/runtime.hpp"
#include "nativebind/signal.hpp"
#include "nativebind/types.hpp"
#include "nativebind/worker.hpp"
