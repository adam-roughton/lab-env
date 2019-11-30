{ 
  stdenv,
  lib,
  coursier,
  writeShellScriptBin,
  jre_headless,
  scalaVersion ? "2.12.8",
}:
let
  scalaVersionMajorMinor = "${lib.versions.majorMinor scalaVersion}";
  almondVersion = "0.6.0";
  drvName = "almond-${almondVersion}_${scalaVersionMajorMinor}";
  dependencies-sha256 = {
     "2.11" = "02larnxdkfimbh5q6c648mh3xmn9f50bp4hncl7mghq4yzq69p0g";
     "2.12" = "1qhjc551yvd76mmps7lmmd2n7mms52zqq2n3m2xzp4k143vg5nwj";
  }.${scalaVersionMajorMinor};

  coursier-standalone-jar = builtins.fetchurl {
     url = "https://repo1.maven.org/maven2/io/get-coursier/coursier-cli_2.12/1.1.0-M14/coursier-cli_2.12-1.1.0-M14-standalone.jar";
     sha256 = "055iq6dpf7d3j4gygnn71a5hh1n86kjixsns5bxafqmz0s0gfmj2";
  };
  coursier-standalone = writeShellScriptBin "coursier-standalone" ''
    ${jre_headless}/bin/java -jar ${coursier-standalone-jar} $@
  '';
in
stdenv.mkDerivation rec {
  inherit scalaVersion;
  name = "${drvName}";
  version = "${almondVersion}";

  src = builtins.fetchGit {
    url = "https://github.com/almond-sh/almond";
    ref = "v${version}";
  };

  nativeBuildInputs = [ coursier-standalone ];

  # inspired by pkgs/applications/networking/cluster/hadoop/default.nix
  dependencies = stdenv.mkDerivation {
    name = "${drvName}-dependencies";
    inherit src nativeBuildInputs;

    buildPhase = ''
      mkdir -p $out/.coursier

      coursier-standalone fetch \
        --cache $out/.coursier \
        -r jitpack \
        sh.almond:scala-kernel_${scalaVersion}:${almondVersion}
    '';

    # keep only *.{pom,jar,xml,sha1,so,dll,dylib} and delete all ephemeral files with lastModified timestamps inside
    installPhase = ''find $out/.coursier -type f -regex '.+\(\.lastUpdated\|resolver-status\.properties\|_remote\.repositories\)' -delete'';
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash =  "${dependencies-sha256}";
  };

  buildPhase = ''
    cp -dpr ${dependencies}/.coursier ./coursier-cache

    coursier-standalone bootstrap \
      --cache ./coursier-cache \
      -r jitpack \
      -m offline \
      -i user -I user:sh.almond:scala-kernel-api_${scalaVersion}:${almondVersion} \
      sh.almond:scala-kernel_${scalaVersion}:${almondVersion} \
      --standalone \
      -o almond
  '';

  installPhase = ''
    mkdir -p $out/bin
    mv almond $out/bin/almond
  '';

} 

