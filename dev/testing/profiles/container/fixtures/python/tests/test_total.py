from total import total


def test_total_sums_positive_and_negative_integers_and_handles_empty_input():
    assert total([2, 3, -1]) == 4
    assert total([]) == 0
    assert total([-4, -2]) == -6
