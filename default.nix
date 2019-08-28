{ ... }:

let
  version = "0.1.0-a1";

  defaultPkgs = import ./pkgs.nix {};
  callPackage = defaultPkgs.callPackage;
  lib = defaultPkgs.lib;

  mkSparkDist = (import ./spark { inherit callPackage lib; }).mkSparkDist;

  wrapLab = lab:
  let
    buildId = builtins.elemAt (builtins.split "-" (builtins.baseNameOf lab.outPath)) 0;
    images = repo : builtins.map (imageDef: imageDef { inherit repo buildId; }) lab.dockerImageDefinitions;
    loadScript = publishConf: with publishConf.docker; defaultPkgs.writeShellScriptBin "load-images.sh" ''
    ${lib.concatMapStrings (img: "echo \"loading ${img.imageName}...\" && cat ${img.image} | docker load\n" ) (images repo)}
    echo "${buildId}"
    '';
    publishScript = publishConf: with publishConf.docker; defaultPkgs.writeShellScriptBin "publish.sh" ''
    ${lib.concatMapStrings (img: "echo \"pushing ${img.imageName}...\" && docker push ${img.imageName}\n" ) (images repo)}
    '';
  in
    lab // {
      dockerImages = { publishConfFile }:
      let
        publishConf = builtins.fromJSON (builtins.readFile publishConfFile);
      in defaultPkgs.runCommand "${lab.name}-docker-images" {} ''
        mkdir $out
        ln -s ${loadScript publishConf}/bin/load-images.sh $out/load-images.sh
        ln -s ${publishScript publishConf}/bin/publish.sh $out/publish.sh
        echo "${buildId}" > $out/buildId
      '';  
    };

  buildJupyterLab = { 
    name ? "lab-env-jupyter-lab",
    spark ? mkSparkDist {
      sparkVersion = "2.4.3";
      scalaVersion = "2.12.8";
    },
    pythonPackages ? (_:[]),
    pkgs ? defaultPkgs 
  }: wrapLab (callPackage ./jupyter-lab-builder.nix { 
    inherit name spark pythonPackages pkgs; 
  });

in { inherit mkSparkDist buildJupyterLab; }
