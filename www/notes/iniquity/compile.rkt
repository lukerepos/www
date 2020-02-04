#lang racket
(provide (all-defined-out))

;; An immediate is anything ending in #b000
;; All other tags in mask #b111 are pointers

(define result-shift     3)
(define result-type-mask (sub1 (arithmetic-shift 1 result-shift)))
(define type-imm         #b000)
(define type-box         #b001)
(define type-pair        #b010)
(define type-string      #b011)

(define imm-shift        (+ 2 result-shift))
(define imm-type-mask    (sub1 (arithmetic-shift 1 imm-shift)))
(define imm-type-int     (arithmetic-shift #b00 result-shift))
(define imm-type-bool    (arithmetic-shift #b01 result-shift))
(define imm-type-char    (arithmetic-shift #b10 result-shift))
(define imm-type-empty   (arithmetic-shift #b11 result-shift))

(define imm-val-false    imm-type-bool)
(define imm-val-true     (bitwise-ior (arithmetic-shift 1 (add1 imm-shift)) imm-type-bool))

;; Allocate in 64-bit (8-byte) increments, so pointers
;; end in #b000 and we tag with #b001 for boxes, etc.

;; type CEnv = (Listof (Maybe Variable))
;; type Imm = Integer | Boolean | Char | ''()

;; type Prog =
;; | Expr
;; | `(begin ,@(Listof (define (,Variable ,@(Listof Variable)) ,Expr))
;;           ,Expr)           

;; Prog -> Asm
(define (compile p)
  (match p
    [(list 'begin `(define (,fs . ,xss) ,es) ... e0)
     (let ((ds (compile-defines fs xss es))
           (c0 (compile-entry e0)))
       `(,@c0
         ,@ds))]
    [e (compile-entry e)]))

;; Expr -> Asm
;; Compile e as the entry point
(define (compile-entry e)
  `(entry
    ,@(compile-e e '())
    ret

    err
    (push rbp)
    (call error)
    ret))

;; Expr CEnv -> Asm
(define (compile-e e c)
  (match e
    [(? symbol? x)         (compile-variable x c)]
    [(? imm? i)            (compile-imm i)]
    [`(box ,e0)            (compile-box e0 c)]
    [`(unbox ,e0)          (compile-unbox e0 c)]
    [`(cons ,e0 ,e1)       (compile-cons e0 e1 c)]
    [`(car ,e0)            (compile-car e0 c)]
    [`(cdr ,e0)            (compile-cdr e0 c)]
    [`(add1 ,e0)           (compile-add1 e0 c)]
    [`(sub1 ,e0)           (compile-sub1 e0 c)]
    [`(zero? ,e0)          (compile-zero? e0 c)]
    [`(empty? ,e0)         (compile-empty? e0 c)]
    [`(if ,e0 ,e1 ,e2)     (compile-if e0 e1 e2 c)]
    [`(+ ,e0 ,e1)          (compile-+ e0 e1 c)]
    [`(let ((,x ,e0)) ,e1) (compile-let x e0 e1 c)]    
    [`(,f . ,es)           (compile-call f es c)]))

;; Variable (Listof Expr) CEnv -> Asm
;; Statically know the function we're calling
(define (compile-call f es c)
  (let ((cs (compile-es es (cons #f c)))
        (stack-size (* 8 (length c))))
    `(,@cs
      (sub rsp ,stack-size)
      (call ,(symbol->label f))
      (add rsp ,stack-size))))

;; (Listof Expr) CEnv -> Asm
(define (compile-es es c)
  (match es
    ['() '()]
    [(cons e es)
     (let ((c0 (compile-e e c))
           (cs (compile-es es (cons #f c))))
       `(,@c0
         (mov (offset rsp ,(- (add1 (length c)))) rax)
         ,@cs))]))

;; Variable (Listof Variable) Expr -> Asm
(define (compile-define f xs e0)
  (let ((c0 (compile-e e0 (reverse xs))))
    `(,(symbol->label f)
      ,@c0
      ret)))

;; (Listof Variable) (Listof (Listof Variable)) (Listof Expr) -> Asm
(define (compile-defines fs xss es)
  (append-map compile-define fs xss es))

;; Any -> Boolean
(define (imm? x)
  (or (integer? x)
      (boolean? x)
      (char? x)
      (equal? ''() x)))

;; Any -> Boolean
(define (type-pred? x)
  (memq x '(integer?
            char?
            empty?)))

;; Imm -> Asm
(define (compile-imm i)
  `((mov rax ,(imm->bits i))))

;; Imm -> Integer
(define (imm->bits i)
  (match i
    [(? integer? i) (arithmetic-shift i imm-shift)]
    [(? char? c)    (+ (arithmetic-shift (char->integer c) imm-shift) imm-type-char)]
    [(? boolean? b) (if b imm-val-true imm-val-false)]
    [''()           imm-type-empty]))

;; Variable CEnv -> Asm
(define (compile-variable x c)
  (let ((i (lookup x c)))
    `((mov rax (offset rsp ,(- (add1 i)))))))

;; Expr CEnv -> Asm
(define (compile-box e0 c)
  (let ((c0 (compile-e e0 c)))
    `(,@c0
      (mov (offset rdi 0) rax)
      (mov rax rdi)
      (or rax ,type-box)
      (add rdi 8)))) ; allocate 8 bytes

;; Expr CEnv -> Asm
(define (compile-unbox e0 c)
  (let ((c0 (compile-e e0 c)))
    `(,@c0
      ,@assert-box
      (xor rax ,type-box)
      (mov rax (offset rax 0)))))

;; Expr Expr CEnv -> Asm
(define (compile-cons e0 e1 c)
  (let ((c0 (compile-e e0 c))
        (c1 (compile-e e1 (cons #f c))))
    `(,@c0
      (mov (offset rsp ,(- (add1 (length c)))) rax)
      ,@c1
      (mov (offset rdi 0) rax)
      (mov rax (offset rsp ,(- (add1 (length c)))))
      (mov (offset rdi 1) rax)
      (mov rax rdi)
      (or rax ,type-pair)
      (add rdi 16))))

;; Expr CEnv -> Asm
(define (compile-car e0 c)
  (let ((c0 (compile-e e0 c)))
    `(,@c0
      ,@assert-pair
      (xor rax ,type-pair)
      (mov rax (offset rax 1)))))

;; Expr CEnv -> Asm
(define (compile-cdr e0 c)
  (let ((c0 (compile-e e0 c)))
    `(,@c0
      ,@assert-pair
      (xor rax ,type-pair)
      (mov rax (offset rax 0)))))

;; Expr CEnv -> Asm
(define (compile-empty? e0 c)
  (let ((c0 (compile-e e0 c))
        (l0 (gensym)))
    `(,@c0
      (and rax ,imm-type-mask)
      (cmp rax ,imm-type-empty)
      (mov rax ,imm-val-false)
      (jne ,l0)
      (mov rax ,imm-val-true)
      ,l0)))

;; Expr CEnv -> Asm
(define (compile-add1 e0 c)
  (let ((c0 (compile-e e0 c)))
    `(,@c0
      ,@assert-integer
      (add rax ,(arithmetic-shift 1 imm-shift)))))

;; Expr CEnv -> Asm
(define (compile-sub1 e0 c)
  (let ((c0 (compile-e e0 c)))
    `(,@c0
      ,@assert-integer
      (sub rax ,(arithmetic-shift 1 imm-shift)))))

;; Expr CEnv -> Asm
(define (compile-zero? e0 c)
  (let ((c0 (compile-e e0 c))
        (l0 (gensym))
        (l1 (gensym)))
    `(,@c0
      ,@assert-integer
      (cmp rax 0)
      (mov rax ,imm-val-false)
      (jne ,l0)
      (mov rax ,imm-val-true)
      ,l0)))

;; Expr Expr Expr CEnv -> Asm
(define (compile-if e0 e1 e2 c)
  (let ((c0 (compile-e e0 c))
        (c1 (compile-e e1 c))
        (c2 (compile-e e2 c))
        (l0 (gensym))
        (l1 (gensym)))
    `(,@c0
      (cmp rax ,imm-val-false)
      (je ,l0)
      ,@c1
      (jmp ,l1)
      ,l0
      ,@c2
      ,l1)))

;; Variable Expr Expr CEnv -> Asm
(define (compile-let x e0 e1 c)
  (let ((c0 (compile-e e0 c))
        (c1 (compile-e e1 (cons x c))))
    `(,@c0
      (mov (offset rsp ,(- (add1 (length c)))) rax)
      ,@c1)))

;; Expr Expr CEnv -> Asm
(define (compile-+ e0 e1 c)
  (let ((c1 (compile-e e1 c))
        (c0 (compile-e e0 (cons #f c))))
    `(,@c1
      ,@assert-integer
      (mov (offset rsp ,(- (add1 (length c)))) rax)
      ,@c0
      ,@assert-integer
      (add rax (offset rsp ,(- (add1 (length c))))))))


(define (type-pred->mask p)
  (match p
    [(or 'box? 'cons? 'string?) result-type-mask]
    [_ imm-type-mask]))

(define (type-pred->tag p)
  (match p
    ['box?     type-box]
    ['cons?    type-pair]
    ['string?  type-string]
    ['integer? imm-type-int]
    ['empty?   imm-type-empty]
    ['char?    imm-type-char]
    ['boolean? imm-type-bool]))

;; Variable CEnv -> Natural
(define (lookup x cenv)
  (match cenv
    ['() (error "undefined variable:" x)]
    [(cons y cenv)
     (match (eq? x y)
       [#t (length cenv)]
       [#f (lookup x cenv)])]))

(define (assert-type p)
  `((mov rbx rax)
    (and rbx ,(type-pred->mask p))
    (cmp rbx ,(type-pred->tag p))
    (jne err)))

(define assert-integer (assert-type 'integer?))
(define assert-box     (assert-type 'box?))
(define assert-pair    (assert-type 'cons?))
(define assert-string  (assert-type 'string?))
(define assert-char    (assert-type 'char?))

;; Asm
(define assert-natural
  `(,@assert-integer
    (cmp rax -1)
    (jle err)))

;; Asm
(define assert-integer-codepoint
  `((mov rbx rax)
    (and rbx ,imm-type-mask)
    (cmp rbx 0)
    (jne err)
    (cmp rax ,(arithmetic-shift -1 imm-shift))
    (jle err)
    (cmp rax ,(arithmetic-shift #x10FFFF imm-shift))
    (mov rbx rax)
    (sar rbx ,(+ 11 imm-shift))
    (cmp rbx #b11011)
    (je err)))

;; Symbol -> Label
;; Produce a symbol that is a valid Nasm label
(define (symbol->label s)
  (string->symbol
   (string-append
    "label_"
    (list->string
     (map (λ (c)
            (if (or (char<=? #\a c #\z)
                    (char<=? #\A c #\Z)
                    (char<=? #\0 c #\9)
                    (memq c '(#\_ #\$ #\# #\@ #\~ #\. #\?)))
                c
                #\_))
         (string->list (symbol->string s))))
    "_"
    (number->string (eq-hash-code s) 16))))
