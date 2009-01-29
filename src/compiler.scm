;;;
;;; The Duna Scheme compiler
;;; Copyright (c) 2009 Alex Queiroz <asandroq@gmail.com>
;;;
;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;; of this software and associated documentation files (the "Software"), to deal
;;; in the Software without restriction, including without limitation the rights
;;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;;; copies of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be included in
;;; all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;;; THE SOFTWARE.
;;;

;; bytecode instructions
(define *opcodes*
  '((LOAD-NIL       . 1)
    (LOAD-FALSE     . 2)
    (LOAD-TRUE      . 3)
    (LOAD-ZERO      . 4)
    (LOAD-ONE       . 5)
    (LOAD-FIXNUM    . 6)
    (LOAD-CHAR      . 7)
    (INC            . 8)
    (DEC            . 9)
    (FIXNUM-TO-CHAR . 10)
    (CHAR-TO-FIXNUM . 11)
    (NULL-P         . 12)
    (ZERO-P         . 13)
    (NOT            . 14)
    (BOOL-P         . 15)
    (CHAR-P         . 16)
    (FIXNUM-P       . 17)
    (PUSH           . 18)
    (POP            . 19)
    (PLUS           . 20)
    (MINUS          . 21)
    (MULT           . 22)
    (LOAD0          . 23)
    (LOAD1          . 24)
    (LOAD2          . 25)
    (LOAD3          . 26)
    (LOAD           . 27)
    (SET-FP         . 28)
    (SAVE-FP        . 29)
    (REST-FP        . 30)
    (CREATE-CLOSURE . 31)
    (CALL           . 32)
    (RETURN         . 33)
    (SAVE-PROC      . 34)
    (SET-PROC       . 35)
    (JMP-IF         . 36)
    (JMP            . 37)
    (CONS           . 38)
    (CAR            . 39)
    (CDR            . 40)))

(define (make-compiler-state)
  (vector
   0                          ;; Index of next instruction
   (make-vector 32 0)))       ;; code vector

(define (write-code-vector cs)
  (write (vector-ref cs 1)))

(define (code-capacity cs)
  (vector-length (vector-ref cs 1)))

(define (code-size cs)
  (vector-ref cs 0))

(define (extend-code-vector! cs)
  (let* ((len (vector-length (vector-ref cs 1)))
         (new-len (round (/ (* 3 len) 2)))
         (new-vec (make-vector new-len 0)))
    (let loop ((i 0))
      (if (= i len)
          (vector-set! cs 1 new-vec)
          (begin
            (vector-set! new-vec i (vector-ref (vector-ref cs 1) i))
            (loop (+ i 1)))))))

(define (add-to-code! cs byte)
  (let ((i (code-size cs)))
    (and (= i (code-capacity cs))
         (extend-code-vector! cs))
    (vector-set! cs 0 (+ i 1))
    (vector-set! (vector-ref cs 1) i byte)))

(define (insert-into-code! cs i byte)
  (vector-set! (vector-ref cs 1) i byte))

(define (instr cs i . args)
  (add-to-code! cs (cdr (assv i *opcodes*)))
  (or (null? args)
      (for-each (lambda (x)
                  (add-to-code! cs x))
                args)))

(define (immediate? x)
  (or (char? x)
      (boolean? x)
      (integer? x)
      (null? x)))

(define (emit-fixnum cs x)
  (let* ((b4 (quotient  x  16777216))
         (x4 (remainder x  16777216))
         (b3 (quotient  x4 65536))
         (x3 (remainder x4 65536))
         (b2 (quotient  x3 256))
         (b1 (remainder x3 256)))
    (add-to-code! cs b1)
    (add-to-code! cs b2)
    (add-to-code! cs b3)
    (add-to-code! cs b4)))

(define (insert-fixnum! cs x i)
  (let* ((b4 (quotient  x  16777216))
         (x4 (remainder x  16777216))
         (b3 (quotient  x4 65536))
         (x3 (remainder x4 65536))
         (b2 (quotient  x3 256))
         (b1 (remainder x3 256)))
    (insert-into-code! cs i b1)
    (insert-into-code! cs (+ i 1) b2)
    (insert-into-code! cs (+ i 2) b3)
    (insert-into-code! cs (+ i 3) b4)))

;; emit code for immediate values
(define (emit-immediate cs x)
  (cond
   ((null? x)
    (instr cs 'LOAD-NIL))
   ((boolean? x)
    (if x
        (instr cs 'LOAD-TRUE)
        (instr cs 'LOAD-FALSE)))
   ((char? x)
    (instr cs 'LOAD-CHAR (char->integer x)))
   ((integer? x)
    (case x
      ((0)
       (instr cs 'LOAD-ZERO))
      ((1)
       (instr cs 'LOAD-ONE))
      (else
       (instr cs 'LOAD-FIXNUM)
       (emit-fixnum cs x))))
   (else
    (error "unknown immediate"))))

(define *primitives*
  '((add1 INC 1)
    (sub1 DEC 1)
    (char->integer CHAR-TO-FIXNUM 1)
    (integer->char FIXNUM-TO-CHAR 1)
    (null? NULL-P 1)
    (zero? ZERO-P 1)
    (not NOT 1)
    (boolean? BOOL-P 1)
    (char? CHAR-P 1)
    (integer? FIXNUM-P 1)
    (+ PLUS 2)
    (- MINUS 2)
    (* MULT 2)
    (cons CONS 2)
    (car CAR 1)
    (cdr CDR 1)))

(define (primitive-call? x)
  (and (pair? x)
       (let ((op (car x)))
         (and (assv op *primitives*) #t))))

(define (compile-primitive-call cs x env)
  (let* ((prim (car x))
         (prim-rec (assv prim *primitives*)))
    (if prim-rec
        (let ((code (cadr prim-rec))
              (arity (caddr prim-rec)))
          (cond
           ((= arity 1)
            (compile-exp cs (cadr x) env)
            (instr cs code))
           ((= arity 2)
            (compile-exp cs (caddr x) env)
            (instr cs 'PUSH)
            (compile-exp cs (cadr x) env)
            (instr cs code))
           (else
            (error "Primitive with unknown arity"))))
        (error "Unknown primitive"))))

(define (lookup var env ret)
  (if (null? env)
      (ret #f #f)
      (let loop ((i 0)
                 (j 0)
                 (sec (car env))
                 (env (cdr env)))
        (if (null? sec)
            (if (null? env)
                (ret #f #f)
                (loop 0 (+ j 1) (car env) (cdr env)))
            (let ((sym (car sec)))
              (if (eq? var sym)
                  (ret i j)
                  (loop (+ i 1) j (cdr sec) env)))))))

(define (compile-seq cs exps env)
  (if (null? exps)
      (instr cs 'LOAD-NIL)
      (for-each (lambda (x)
                  (compile-exp cs x env))
                exps)))

(define (compile-conditional cs test then else env)
  (compile-exp cs test env)
  (instr cs 'JMP-IF)
  (let ((i (code-size cs)))
    ;; this will be back-patched later
    (emit-fixnum cs 0)
    (compile-exp cs else env)
    (instr cs 'JMP)
    (let ((j (code-size cs)))
      ;; this will be back-patched later
      (emit-fixnum cs 0)
      (let ((k (code-size cs)))
        ;; back-patching if jump
        (insert-fixnum! cs (- k i 4) i)
        (compile-exp cs then env)
        (let ((m (code-size cs)))
          ;; back-patching else jmp
          (insert-fixnum! cs (- m j 4) j))))))

(define (compile-closure cs vars body env)
  (instr cs 'CREATE-CLOSURE)
  (let ((i (code-size cs))
        (new-env (cons (reverse vars) '())))
    ;; this will be back-patched later
    (emit-fixnum cs 0)
    (compile-seq cs body new-env)
    (instr cs 'POP)
    (instr cs 'REST-FP)
    (instr cs 'RETURN)
    (let ((j (- (code-size cs) i 4)))
      ;; back patching jump before closure code
      (insert-fixnum! cs j i))))

(define (compile-let cs vars args body env)
  (instr cs 'SAVE-FP)
  (let loop ((new-env '())
             (vars vars)
             (args args))
    (if (null? vars)
        (let ((len (length new-env)))
          (instr cs 'SET-FP)
          (emit-immediate cs len)
          (instr cs 'PUSH)
          (compile-seq cs body (cons new-env env))
          (instr cs 'POP)
          (instr cs 'REST-FP))
        (let ((var (car vars))
              (exp (car args)))
          (compile-exp cs exp env)
          (instr cs 'PUSH)
          (loop (cons var new-env) (cdr vars) (cdr args))))))

(define (compile-application cs proc args env)
  (instr cs 'SAVE-PROC)
  (instr cs 'LOAD-FIXNUM)
  (let ((i (code-size cs)))
    ;; this is the return address, will be back-patched later
    (emit-fixnum cs 0)
    (instr cs 'PUSH)
    (instr cs 'SAVE-FP)
    (let ((len (length args)))
      (let loop ((args args))
        (if (null? args)
            (begin
              (compile-exp cs proc env)
              (instr cs 'SET-PROC)
              (instr cs 'SET-FP)
              (emit-immediate cs len)
              (instr cs 'PUSH)
              (instr cs 'CALL)
              ;; back-patching return address
              (insert-fixnum! cs (code-size cs) i))
            (let ((arg (car args)))
              (compile-exp cs arg env)
              (instr cs 'PUSH)
              (loop (cdr args))))))))

(define (compile-exp cs x env)
  (cond
   ((immediate? x)
    (emit-immediate cs x))
   ((symbol? x)
    (let ((cont (lambda (i j)
                  (if i
                      (if (zero? j)
                          (case i
                            ((0)
                             (instr cs 'LOAD0))
                            ((1)
                             (instr cs 'LOAD1))
                            ((2)
                             (instr cs 'LOAD2))
                            ((3)
                             (instr cs 'LOAD3))
                            (else
                             (instr cs 'LOAD)
                             (emit-fixnum cs i)
                             (emit-fixnum cs 0)))
                          (begin
                            (instr cs 'LOAD)
                            (emit-fixnum cs i)
                            (emit-fixnum cs j)))
                      (error "Unknown binding!")))))
      (lookup x env cont)))
   ((primitive-call? x)
    (compile-primitive-call cs x env))
   ((pair? x)
    (case (car x)
      ((begin)
       (compile-seq cs (cdr x) env))
      ((if)
       (compile-conditional cs (cadr x) (caddr x) (cadddr x) env))
      ((lambda)
       (compile-closure cs (cadr x) (cddr x) env))
      ((let)
       (let ((bindings (cadr x)))
         (let ((vars (map car  bindings))
               (args (map cadr bindings)))
           (compile-let cs vars args (cddr x) env))))
      (else
       (let ((op (car x)))
         (if (and (pair? op)
                  (eq? (car op) 'lambda))
             (compile-let cs (cadr op) (cdr x) (cddr op) env)
             (compile-application cs op (cdr x) env))))))
   (else
    (error "Cannot compile atom"))))

(define (compile cs* x)
  (let ((cs (or cs* (make-compiler-state))))
    (compile-exp cs x '())
    (write-code-vector cs)))

(define (compile-to-file file x)
  (with-output-to-file file
    (lambda ()
      (compile #f x))))

