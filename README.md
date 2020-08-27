![logo](logo/logo.png)

# raylib-ocaml

OCaml bindings for <a href="https://www.raylib.com/" target="_blank">raylib</a> (v3.0.0), a simple and easy-to-use library to enjoy videogames programming.

The bindings are pretty faithful to the original C code, the biggest difference is the conversion of all function name from CamelCase to snake_case. Wherever possible, integer arguments are changed to their own variant types, eg. `int key` to `Key.t`.

Bindings exists for (nearly) all functions and types, but only a subset are tested thus far (see examples folder). Rough edges are to be expected.

## Example

``` ocaml
let setup () =
  Raylib.init_window 800 450 "raylib [core] example - basic window";
  Raylib.set_target_fps 60

let rec loop () =
  match Raylib.window_should_close () with
  | true -> Raylib.close_window ()
  | false ->
      let open Raylib in
      begin_drawing ();
      clear_background Color.raywhite;
      draw_text "Congrats! You created your first window!" 190 200 20
        Color.lightgray;
      end_drawing ();
      loop ()

let () = setup () |> loop
```
Further examples can be found in the examples folder.

## Building

Currently, the automated build works only on Linux. A Windows build (mingw64 pins) is possible, but requires a bit of manual fiddling. The library is built with cmake from source, therefore cmake and raylib's dependencies must be present, for details see <a href="https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux" target="_blank">here</a>.

From the OCaml side, the library depends on `ctypes` and `ppx_cstubs` and uses `dune` as its build system:

``` sh
dune build
```

This also builds the examples.

## TODO
* Write further tests to cover the whole surface of raylib
* Split the library into components (core, sound, 3D, VR etc) for a smaller memory footprint
* Provide some ergonomics (somehow?)