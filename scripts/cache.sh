#!/usr/bin/env bash

check_phar() {
    phar=$1
    echo "Checking $phar"
    php -r "try {\$p=new Phar('$phar', 0);exit(0);} catch(Exception \$e) {exit(1);}"
    if [ $? -eq 1 ]; then
        echo "ERROR: Broken $phar found"
        exit 1
    else
        php "$phar" -V
    fi
}

fetch_phar_for_php_version() {
    php_version=$1
    channel=$2
    installer=$3
    php_version_semver="$php_version.99"
    php_version_id=$(echo "${php_version_semver}" | awk 'BEGIN { FS = "."; } { printf "%d", ($1 * 100 + $2) * 100 + $3;}')
    cp -f "$installer" "$installer-${php_version}"
    sed -i -e "s/PHP_VERSION_ID/'$php_version_id'/g" -e "s/PHP_VERSION/'$php_version_semver'/g" "$installer-${php_version}"
    php "$installer-${php_version}" --"${channel}" --install-dir="$(pwd)" --filename=composer-"${php_version}"-"${channel}".phar
    check_phar composer-"${php_version}"-"${channel}".phar    
}

fetch_installer() {
    installer=$1
    EXPECTED_CHECKSUM="$(curl -sL https://composer.github.io/installer.sig)"
    curl -o "$installer" -sL https://getcomposer.org/installer
    ACTUAL_CHECKSUM="$(openssl dgst -sha384 "$installer" | cut -d ' ' -f 2)"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        echo 'ERROR: Invalid installer checksum'
        exit 1
    fi
}

clear_cf_cache() {
    curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$CF_CACHE_ZONE/purge_cache" \
        -H "Authorization: Bearer $CF_CACHE_KEY" -H "Content-Type: application/json" \
        --data '{"tags":["composer-rolling"]}'
}

upload_to_s3() {
    for asset in "$@"; do
        aws --endpoint-url $AWS_S3_ENDPOINT s3 cp "$asset" "s3://composer/$(basename "$asset")" --only-show-errors
    done
    clear_cf_cache
}

update_release() {
    release=$1
    release_notes_file=$2
    assets=()
    for asset in ./*.phar; do
        assets+=("$asset")
    done
    assets+=("$release_notes_file")
    echo "${assets[@]}"
    if ! gh release view "$release"; then
        gh release create "$release" "${assets[@]}"  -t "$release" -F "$release_notes_file"
    else
        gh release upload "$release" "${assets[@]}" --clobber
        gh release edit "$release" --notes-file "$release_notes_file"
    fi
    upload_to_s3 "${assets[@]}"
    echo "${assets[@]}" | xargs -n 1 -P 2 cds
}

check_manifest() {
    manifest_file=$1
    release=$2
    curl -o "$manifest_file" -sSL https://getcomposer.org/versions
    release_versions="$(curl -sSL https://github.com/"$GITHUB_REPOSITORY"/releases/latest/download/"$release")"
    if [ "$FORCE" != 'true' ] && [ "$(cat "$manifest_file")" = "$release_versions" ]; then
        echo "No new releases"
        exit 0
    fi
}

install_cloudsmith() {
    pip3 install --upgrade cloudsmith-cli
    sudo cp ./scripts/cds /usr/local/bin/cds
    sudo sed -i "s|REPO|$GITHUB_REPOSITORY|" /usr/local/bin/cds
    sudo chmod a+x /usr/local/bin/cds
}

install_awscli() {
    if ! command -v aws >/dev/null 2>&1; then
        pip3 install --upgrade awscli >/dev/null
    fi
}

channels=(stable preview snapshot 1 2)
php_versions=(5.3 5.4 5.5 5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5)
release=versions
manifest_file=versions
installer=installer


check_manifest "$manifest_file" "$release"

for channel in "${channels[@]}"; do
    curl -o composer-"$channel".phar -sSL https://getcomposer.org"$(jq -r ".\"$channel\"[].path" "$manifest_file" | head -n 1)"
    check_phar composer-"$channel".phar

    fetch_installer "$installer"
    for php_version in "${php_versions[@]}"; do
        fetch_phar_for_php_version "$php_version" "$channel" "$installer"
    done
done

install_awscli
install_cloudsmith
update_release "$release" "$manifest_file"
