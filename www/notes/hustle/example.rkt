#lang racket
(let ((x (cons 1 (cons 2 (cons (+ 0 0) '()))))) (map-zero? (cdr x)))