{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        android_sdk.accept_license = true;
      };
    };
    lib = pkgs.lib;

    androidSdk =
      (pkgs.androidenv.composeAndroidPackages {
        platformVersions = ["36" "35" "34"];
        buildToolsVersions = ["36.0.0" "35.0.0" "34.0.0"];
        ndkVersions = ["27.0.12077973"];
        includeNDK = true;
        cmakeVersions = ["3.22.1"];
        includeCmake = true;
        includeEmulator = false;
      }).androidsdk;

    sdkRoot = "${androidSdk}/libexec/android-sdk";

    shell = pkgs.mkShell {
      name = "dev-shell";
      packages = with pkgs; [
        flutter
        dart
        androidSdk
        android-tools
        jdk17
        just
        rustc
        cargo
        clippy
        rustfmt
        pkg-config
        mold
        cargo-watch
        sqlite
        sqlx-cli
        watchexec
        github-copilot-cli
      ];

      RUSTFLAGS = "-C link-arg=-fuse-ld=mold";

      ANDROID_SDK_ROOT = sdkRoot;
      ANDROID_HOME = sdkRoot;
      JAVA_HOME = "${pkgs.jdk17}/lib/openjdk";
    };

    webBuild = pkgs.flutter.buildFlutterApplication {
      pname = "mont-web";
      version = "0.1.0";
      src = pkgs.lib.cleanSource ./flutter;
      autoPubspecLock = ./flutter/pubspec.lock;
      targetFlutterPlatform = "web";
    };

    package = pkgs.rustPlatform.buildRustPackage {
      pname = "mont";
      version = "0.1.0";
      src = ./backend;

      cargoLock = {
        lockFile = ./backend/Cargo.lock;
      };

      nativeBuildInputs = with pkgs; [
        pkg-config
      ];

      buildInputs = with pkgs; [
        sqlite
        openssl
      ];

      preBuild = ''
        mkdir -p web_build
        cp -r ${webBuild}/* web_build/
      '';

      doCheck = false;

      meta = with lib; {
        description = "Workout and run tracker backend";
        homepage = "https://github.com/MathieuMoalic/mont";
        license = licenses.gpl3;
        maintainers = [];
      };
    };

    prebuilt = pkgs.stdenvNoCC.mkDerivation {
      pname = "mont";
      version = "0.2.0";

      src = pkgs.fetchurl {
        url = "https://github.com/MathieuMoalic/mont/releases/download/v0.2.0/mont-v0.2.0-x86_64-linux.tar.gz";
        hash = "sha256-SKYdnYIatdSjws+7k9/G+mauoVYz/YB7Bi8oDidlt1Q=";
      };

      sourceRoot = ".";

      installPhase = ''
        install -Dm755 mont-v0.2.0-x86_64-linux $out/bin/mont
      '';

      meta = with lib; {
        description = "Workout and run tracker backend (prebuilt)";
        homepage = "https://github.com/MathieuMoalic/mont";
        license = licenses.gpl3;
        platforms = ["x86_64-linux"];
        maintainers = [];
      };
    };

    service = {
      lib,
      config,
      pkgs,
      ...
    }: let
      cfg = config.services.mont;
    in {
      options.services.mont = {
        enable = lib.mkEnableOption "Mont workout tracker backend";

        package = lib.mkOption {
          type = lib.types.package;
          default = package;
          description = "The mont package to use.";
        };

        bindAddr = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1:8080";
          description = "Address to bind the HTTP server to";
        };

        databasePath = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/mont/mont.sqlite";
          description = "Path to SQLite database file";
        };

        logFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/mont/mont.log";
          description = "Path to log file";
        };

        corsOrigin = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "https://mont.yourdomain.com";
          description = "CORS allowed origin. If null, allows any origin";
        };

        verbosity = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Log verbosity level (-2 to 3, where 0 is info)";
        };

        passwordHash = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Argon2 password hash. Generate with: mont hash-password";
        };

        passwordHashFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to file containing password hash (for sops-nix)";
        };

        jwtSecret = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "JWT secret. If not set, generates a random one.";
        };

        jwtSecretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to file containing JWT secret (for sops-nix)";
        };

        gadgetbridgePath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to Gadgetbridge data directory (expects files/ and database/Gadgetbridge inside)";
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.passwordHash != null || cfg.passwordHashFile != null;
            message = "services.mont.passwordHash or services.mont.passwordHashFile must be set";
          }
          {
            assertion = !(cfg.passwordHash != null && cfg.passwordHashFile != null);
            message = "services.mont.passwordHash and services.mont.passwordHashFile are mutually exclusive";
          }
          {
            assertion = !(cfg.jwtSecret != null && cfg.jwtSecretFile != null);
            message = "services.mont.jwtSecret and services.mont.jwtSecretFile are mutually exclusive";
          }
        ];

        users.users.mont = {
          isSystemUser = true;
          group = "mont";
          home = "/var/lib/mont";
          createHome = true;
        };
        users.groups.mont = {};

        systemd.tmpfiles.rules = [
          "d ${dirOf cfg.databasePath} 0750 mont mont - -"
          "d ${dirOf cfg.logFile} 0750 mont mont - -"
          "f ${cfg.logFile} 0640 mont mont - -"
        ];

        systemd.services.mont = {
          description = "Mont workout tracker backend";
          after = ["network.target"];
          wantedBy = ["multi-user.target"];

          environment =
            {
              MONT_BIND_ADDR = cfg.bindAddr;
              MONT_DATABASE_PATH = cfg.databasePath;
              MONT_LOG_FILE = cfg.logFile;
            }
            // lib.optionalAttrs (cfg.corsOrigin != null) {MONT_CORS_ORIGIN = cfg.corsOrigin;}
            // lib.optionalAttrs (cfg.passwordHash != null) {MONT_PASSWORD_HASH = cfg.passwordHash;}
            // lib.optionalAttrs (cfg.jwtSecret != null) {MONT_JWT_SECRET = cfg.jwtSecret;}
            // lib.optionalAttrs (cfg.gadgetbridgePath != null) {MONT_GADGETBRIDGE_PATH = cfg.gadgetbridgePath;};

          script = let
            passwordHashLoader =
              if cfg.passwordHashFile != null
              then ''export MONT_PASSWORD_HASH="$(cat ${cfg.passwordHashFile})"''
              else "";
            jwtSecretLoader =
              if cfg.jwtSecretFile != null
              then ''export MONT_JWT_SECRET="$(cat ${cfg.jwtSecretFile})"''
              else "";
          in ''
            ${passwordHashLoader}
            ${jwtSecretLoader}
            exec ${cfg.package}/bin/mont \
              ${lib.concatStringsSep " " (
              lib.optionals (cfg.verbosity > 0) (lib.genList (_: "-v") cfg.verbosity)
              ++ lib.optionals (cfg.verbosity < 0) (lib.genList (_: "-q") (- cfg.verbosity))
            )}
          '';

          serviceConfig = {
            WorkingDirectory = "/var/lib/mont";
            User = "mont";
            Group = "mont";
            StateDirectory = "mont";
            Restart = "always";
            RestartSec = "5s";
            NoNewPrivileges = "yes";
            PrivateTmp = "yes";
            ProtectSystem = "strict";
            ReadWritePaths = [(dirOf cfg.databasePath)];
            SocketBindAllow = let
              port = lib.last (lib.splitString ":" cfg.bindAddr);
            in ["tcp:${port}"];
            SocketBindDeny = "any";
          };
        };
      };
    };
  in {
    devShells.${system}.default = shell;
    nixosModules.mont-service = service;
    packages.${system} = {
      default = package;
      backend = package;
      prebuilt = prebuilt;
      web = webBuild;
    };
  };
}
