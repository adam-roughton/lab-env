{ almond,
  jre_headless,
  stdenv,
  lib,
  runCommand,
  displayName ? null,
  predefCode ? null
}:
let
  name = "almond-kernel-${almond.version}-${almond.scalaVersion}"; 

  kernelFile = {
    language = "scala";
    display_name = (if displayName == null then
      "Scala ${almond.scalaVersion}"
    else
      displayName);
    argv = [
      "${jre_headless}/bin/java"
      "-jar"
      "${almond}/bin/almond"
      "--connection-file"
      "{connection_file}"
    ] ++ (if predefCode != null then [
      "--predef-code"
      "${predefCode}"  
    ] else []);
   
    logo64 = "logo-64x64.png";
  };
  
  almond-kernel-spec = runCommand name {
     buildInputs = [ jre_headless ]; 
   } ''
   mkdir -p $out/kernels/almond

   mkdir tmpJup
   ${almond}/bin/almond --install --jupyter-path tmpJup --copy-launcher false

   cp tmpJup/scala/logo-64x64.png $out/kernels/almond/logo-64x64.png
   echo '${builtins.toJSON kernelFile}' > $out/kernels/almond/kernel.json
  '';
 
in
  {
    spec = almond-kernel-spec;
    runtimePackages = [];
  }
