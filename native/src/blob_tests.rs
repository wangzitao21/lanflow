use super::*;
use crate::tests::{cleanup, root};

#[test]
fn interrupted_staged_chunks_keep_the_last_durable_offset_and_release_writers() {
    let root = root();
    initialize(&root).unwrap();
    let bytes = b"abcdefghijklmnopqrstuvwxyz012345";
    let hash = digest(bytes);
    let begin = |range: &str, length: u64| {
        dispatch(json!({"op":"blob_begin","root":root,"digest":hash,"range":range,"length":length}))
            .unwrap()
    };
    let first = begin("bytes 0-7/32", 8);
    fs::write(first["path"].as_str().unwrap(), &bytes[..8]).unwrap();
    dispatch(json!({"op":"blob_finish","id":first["id"]})).unwrap();
    let interrupted = begin("bytes 8-31/32", 24);
    fs::write(interrupted["path"].as_str().unwrap(), &bytes[8..12]).unwrap();
    let busy = dispatch(json!({"op":"blob_read","root":root,"digest":hash,"size":32,"head":true}))
        .unwrap_err();
    assert_eq!(errors::status(busy.as_ref()), 503);
    assert!(dispatch(json!({"op":"blob_finish","id":interrupted["id"]})).is_err());
    let head = dispatch(json!({"op":"blob_read","root":root,"digest":hash,"size":32,"head":true}))
        .unwrap();
    assert_eq!(head["offset"], 8);
    let abandoned = begin("bytes 8-31/32", 24);
    fs::write(abandoned["path"].as_str().unwrap(), &bytes[8..12]).unwrap();
    dispatch(json!({"op":"close","root":root})).unwrap();
    assert!(!Path::new(abandoned["path"].as_str().unwrap()).exists());
    initialize(&root).unwrap();
    let resumed = begin("bytes 8-31/32", 24);
    fs::write(resumed["path"].as_str().unwrap(), &bytes[8..]).unwrap();
    dispatch(json!({"op":"blob_finish","id":resumed["id"]})).unwrap();
    assert_eq!(fs::read(attachments::path(&root, &hash)).unwrap(), bytes);
    assert_eq!(fs::read_dir(layout::incoming(&root)).unwrap().count(), 0);
    cleanup(&root);
}

#[test]
fn upload_limit_same_digest_exclusion_and_abort_are_shared_across_callers() {
    let root = root();
    initialize(&root).unwrap();
    let mut jobs = Vec::new();
    for index in 0..4 {
        let hash = digest(&[index]);
        jobs.push(
            dispatch(json!({"op":"blob_begin","root":root,"digest":hash,"length":1})).unwrap(),
        );
    }
    for hash in [digest(&[0]), digest(&[5])] {
        let error =
            dispatch(json!({"op":"blob_begin","root":root,"digest":hash,"length":1})).unwrap_err();
        assert_eq!(errors::status(error.as_ref()), 503);
    }
    for job in jobs {
        dispatch(json!({"op":"blob_abort","id":job["id"]})).unwrap();
    }
    assert_eq!(fs::read_dir(layout::incoming(&root)).unwrap().count(), 0);
    let job =
        dispatch(json!({"op":"blob_begin","root":root,"digest":digest(&[0]),"length":1})).unwrap();
    dispatch(json!({"op":"blob_abort","id":job["id"]})).unwrap();
    cleanup(&root);
}
