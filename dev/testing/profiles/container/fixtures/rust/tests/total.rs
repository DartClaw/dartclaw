use container_coding_fixture::total;

#[test]
fn total_sums_positive_and_negative_integers_and_handles_empty_input() {
    assert_eq!(total(&[2, 3, -1]), 4);
    assert_eq!(total(&[]), 0);
    assert_eq!(total(&[-4, -2]), -6);
}
