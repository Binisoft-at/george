# George – common tasks. The Xcode project is generated from project.yml (never committed).
SHELL := /bin/bash
APP := George
DERIVED := build
XCBEAUTIFY := $(shell command -v xcbeautify || echo cat)

.PHONY: generate open test check build build-ios build-mac build-watch library clean

generate:       ## Generate George.xcodeproj (uses XcodeGen; downloads a pinned copy if missing)
	scripts/ci/xcodegen.sh generate

open: generate  ## Generate and open in Xcode
	open $(APP).xcodeproj

test:           ## Core tests (also run on Linux in CI)
	swift test --package-path Packages/$(APP)Core

check:          ## Without a Mac: Core tests (Docker swift:6.2-noble or a local toolchain) + swiftc -parse of the app code
	scripts/ci/local-check.sh

build:          ## The same unsigned builds CI runs (macOS + iOS with the watch app)
	scripts/ci/build.sh

build-ios: generate
	set -o pipefail && xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO build 2>&1 | tee ios-build.log | $(XCBEAUTIFY)

## The iOS build already builds the embedded watch app; this builds only the watch app.
build-watch: generate
	set -o pipefail && xcodebuild -project $(APP).xcodeproj -scheme $(APP)Watch -configuration Debug \
		-destination 'generic/platform=watchOS Simulator' -derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO build 2>&1 | tee watch-build.log | $(XCBEAUTIFY)

build-mac: generate
	set -o pipefail && xcodebuild -project $(APP).xcodeproj -scheme $(APP)Mac -configuration Debug \
		-destination 'generic/platform=macOS' -derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO build 2>&1 | tee mac-build.log | $(XCBEAUTIFY)

library:        ## Rebuild the bundled exercise library
	python3 scripts/build_exercise_db.py data/free-exercise-db.json data/curated_exercises.json App/Resources/exercises.json

clean:
	rm -rf $(DERIVED) $(APP).xcodeproj Packages/$(APP)Core/.build ci-logs *.log
