import os
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import deque

project = pathlib.Path(__file__).resolve().parents[2]
cache = pathlib.Path(sys.argv[1]) / 'caches/modules-2/files-2.1'
android = next((path for path in (project / 'platforms/android', project / 'android')
                if (path / 'settings.gradle.kts').is_file()), None)
if android is None:
    raise RuntimeError('Cannot find the Android platform sources.')
match = re.search(
    r'id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+"([^"]+)"',
    (android / 'settings.gradle.kts').read_text(encoding='utf-8'),
)
if match is None:
    raise RuntimeError('Cannot find the Kotlin version in settings.gradle.kts.')
version = match.group(1)


def cached_file(group, artifact, release, extension):
    directory = cache / group / artifact / release
    matches = sorted(directory.glob(f'*/{artifact}-{release}.{extension}'))
    if not matches:
        raise RuntimeError(
            f'Missing cached compiler dependency: {group}:{artifact}:{release} '
            f'({extension}). Build the Android project first to populate its Gradle cache.'
        )
    return matches[0]


def compiler_classpath():
    # Resolve the compiler's published runtime dependencies, not unrelated or
    # obsolete versions that happen to remain in the Gradle cache.
    namespace = {'m': 'http://maven.apache.org/POM/4.0.0'}
    pending = deque([('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', version, ())])
    resolved = {}
    while pending:
        group, artifact, release, exclusions = pending.popleft()
        key = (group, artifact)
        if key in resolved:
            continue
        resolved[key] = str(cached_file(group, artifact, release, 'jar'))
        if ('*', '*') in exclusions:
            continue
        pom = ET.parse(cached_file(group, artifact, release, 'pom')).getroot()
        properties = {'project.version': release, 'pom.version': release}
        for child in pom.findall('m:properties/*', namespace):
            properties[child.tag.split('}')[-1]] = child.text or ''

        def value(element, name, default=''):
            text = element.findtext(f'm:{name}', default, namespace).strip()
            return re.sub(r'\$\{([^}]+)\}', lambda found: properties.get(found[1], found[0]), text)

        for dependency in pom.findall('m:dependencies/m:dependency', namespace):
            if (value(dependency, 'scope', 'compile') not in ('compile', 'runtime')
                    or value(dependency, 'optional') == 'true'):
                continue
            dependency_group = value(dependency, 'groupId')
            dependency_artifact = value(dependency, 'artifactId')
            if any(eg in ('*', dependency_group) and ea in ('*', dependency_artifact)
                   for eg, ea in exclusions):
                continue
            dependency_version = value(dependency, 'version')
            if (not dependency_version or '${' in dependency_version
                    or value(dependency, 'type', 'jar') != 'jar'
                    or value(dependency, 'classifier')):
                raise RuntimeError(f'Unsupported compiler dependency in {group}:{artifact}:{release}.')
            excluded = tuple((value(item, 'groupId'), value(item, 'artifactId'))
                             for item in dependency.findall('m:exclusions/m:exclusion', namespace))
            pending.append((dependency_group, dependency_artifact, dependency_version,
                            exclusions + excluded))
    return resolved


dependencies = compiler_classpath()
stdlib = dependencies[('org.jetbrains.kotlin', 'kotlin-stdlib')]
annotations = dependencies[('org.jetbrains', 'annotations')]
output = project / 'build/android-policy-jvm'
output.mkdir(parents=True, exist_ok=True)
subprocess.run([
    'java', '-cp', os.pathsep.join(dependencies.values()), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib', '-no-reflect', '-jvm-target', '17',
    '-classpath', os.pathsep.join([stdlib, annotations]), '-d', str(output),
    str(android / 'app/src/main/kotlin/dev/lanflow/app/ShareRecovery.kt'),
    str(android / 'app/src/main/kotlin/dev/lanflow/app/DiscoveryWindow.kt'),
    str(android / 'app/src/main/kotlin/dev/lanflow/app/ReceiverActivityPolicy.kt'),
    str(project / 'test/android/share_recovery_test.kt'),
    str(project / 'test/android/discovery_window_test.kt'),
    str(project / 'test/android/receiver_activity_test.kt'),
], check=True)
for entry in ('Share_recovery_testKt', 'Discovery_window_testKt', 'Receiver_activity_testKt'):
    subprocess.run(['java', '-cp', os.pathsep.join([str(output), stdlib]), f'dev.lanflow.app.{entry}'], check=True)
