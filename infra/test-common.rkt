#lang racket

(require generic-flonum)
(require "../src/common.rkt" "../src/evaluator.rkt" "../src/fpcore-interpreter.rkt" "../src/fpcore-reader.rkt"
         "../src/range-analysis.rkt" "../src/sampler.rkt" "../src/supported.rkt")
(provide tester *tester* test-core run-with-time-limit
         *prog* *ignore-by-run* *last-run* *tool-time-limit*
         value->string value->real ->value)

(module+ test
  (require rackunit))

(define fuel-good-input (make-parameter 1000))
(define fuel-bad-input (make-parameter 100))
(define tests-to-run (make-parameter 10))
(define ulps (make-parameter 0))
(define test-file (make-parameter #f))
(define verbose (make-parameter #f))
(define quiet (make-parameter #f))
(define exact-out (make-parameter #f))
(define use-precond (make-parameter #t))
(define suppress-failures (make-parameter #f))
(define *ignore-by-run* (make-parameter #f))  ; list of booleans that specify if a specific run should be ignored
(define *prog* (make-parameter #f))   ; interpreted languages can store converted core here
(define *last-run* (make-parameter #f))
(define *tool-time-limit* (make-parameter 30)) ; tool run time limit

; Common test structure
(struct tester (name compile run equality format-args format-output filter supported run-once?))
(define *tester* (make-parameter #f))

(define (compile-test prog ctx type test-file)
  ((tester-compile (*tester*)) prog ctx type test-file))

(define (run-test exec-name ctx type number)
  (cond
    [(and (tester-run-once? (*tester*)) (zero? number))
      (let ([res ((tester-run (*tester*)) exec-name ctx type number)])
        (*last-run* res)
        res)]
    [(tester-run-once? (*tester*)) (*last-run*)]
    [else ((tester-run (*tester*)) exec-name ctx type number)]))

(define (format-args var val type)
  ((tester-format-args (*tester*)) var val type))

(define (format-output result)
  ((tester-format-output (*tester*)) result))
  
(define (filter-core prog)    ; allows a tester to reject an fpcore based on precondition, property, etc.
  ((tester-filter (*tester*)) prog))

(define (=* a b type [ignore? #f])
  ((tester-equality (*tester*)) a b (ulps) type ignore?))

;;; Misc

(define (run-with-time-limit exe #:time-limit [time-limit (*tool-time-limit*)] . args)
  (define t0 (current-seconds))
  (define-values (p stdout stdin stderr)
    (apply subprocess #f #f #f (find-executable-path exe) args))
  (close-output-port stdin)
  (let loop ()
    (cond
      [(integer? (subprocess-status p))
        (define p* (input-port-append #t stdout stderr))
        (port->string p* #:close? #t)]
      [(> (- (current-seconds) t0) time-limit)
        (subprocess-kill p #t)
        "timeout"]
      [else
        (sleep 1)
        (loop)])))

(define (value->string x)
  (match x
   [(? gfl?)  (gfl->string x)]
   [(? real?) (~a x)]))

(define (value->real x)
  (match x
   [(? gfl?)  (gfl->real x)]
   [(? real?) x]))

(define (->float x prec)
  (define-values (es nbits)
    (match prec
     ['binary80 (values 15 80)]
     ['binary64 (values 11 64)]
     ['binary32 (values 8 32)]))
  (parameterize ([gfl-exponent es] [gfl-bits nbits])
    (if (gfl? x) (gflcopy x) (gfl x))))
  
(define (->value x prec)
  (match (cons x prec)
   [(cons (? gfl?) 'integer)  (round (gfl->real x))]
   [(cons (? string?) 'integer) (string->number x)]
   [(cons (? real?) 'integer) x]  
   [else (->float x prec)]))

(define (value-nan? x)
  (match x
   [(? gfl?) (gflnan? x)]
   [(? real?) (real? x)]))

;;; Evaluator

(define ((eval-fuel-expr evaltor fuel [default #f]) expr ctx)
  (let/ec k
    (let eval ([expr expr] [ctx ctx] [fuel fuel])
      (if (<= fuel 0)
          (k default)
          ((eval-expr* evaltor (λ (expr ctx) (eval expr ctx (- fuel 1)))) expr ctx)))))

;;; Tester core

(define (test-core argv curr-in-port source default-file)
  (command-line
  #:program "Tester"
  #:once-each
  ["--fuel" fuel_ "Number of computation steps to allow" (fuel-good-input (string->number fuel_))]
  ["--repeat" repeat_ "Number of times to test each program" (tests-to-run (string->number repeat_))]
  ["--error" ulps_ "Error, in ULPs, allowed for libc inaccuracies (probably use a value around 3)" (ulps (string->number ulps_))]
  ["--very-verbose" "Very verbose" (verbose #t) (exact-out #t)]
  ["--exact-output" "Exact compiler output" (exact-out #t)]
  [("-o" "--output") name_ "Name for generated C file" (test-file name_)]
  [("-v" "--verbose") "Verbose" (verbose #t)]
  [("-q" "--quiet") "Quiet" (quiet #t)]
  ["--no-precond" "No precondition evaluation" (use-precond #f)]
  [("-s" "--suppress") "Supresses any failures" (suppress-failures #t)]
  #:args ()
  (when (and (verbose) (quiet)) 
      (error "Verbose and quiet flags cannot be both set"))
  (define err 0)
  (define ignored 0)
  (when (equal? (test-file) #f) (test-file default-file))
  (for ([prog (in-port (curry read-fpcore source) curr-in-port)]
        #:when (and (valid-core prog (tester-supported (*tester*))) (filter-core prog)))   
   (parameterize ([*ignore-by-run* (make-list (tests-to-run) #f)])
    (define-values (vars props* body)
     (match prog
      [(list 'FPCore (list args ...) props ... body) (values args props body)]
      [(list 'FPCore name (list args ...) props ... body) (values args props body)]))
    (define-values (_ props) (parse-properties props*))
    (define type (dict-ref props ':precision 'binary64))
    (define rnd-mode (dict-ref props ':round 'nearestEven))
    (define precond-override (dict-ref props ':fpbench-pre-override '()))
    (define ulps-override (dict-ref props ':fpbench-allowed-ulps #f))
    (define precond (if (empty? precond-override) (dict-ref props ':pre '()) precond-override)) 
    (define range-table (condition->range-table precond))
    (define exec-name (compile-test prog '() type (test-file)))
    (define timeout 0)
    (define nans 0) ; wolfram only

    (define-values (vars* var-types)
      (for/lists (n t) ([var vars])
        (match var
          [(list '! props ... name) (values name (dict-ref (apply hash-set* #hash() props) ':precision 'binary64))]
          [name (values name type)])))
    (define evaltor (get-evaluator (expand-prec type) rnd-mode))

    (define results  ; run test
      (parameterize ([ulps (if (equal? ulps-override #f) ulps ulps-override)])
        (for/list ([i (in-range (tests-to-run))])
          ; Sample points
          (define-values (ctx precond-met)
            (cond 
              [(or (not (use-precond)) (equal? precond '()))                  ; --no-precond flag or no precondition
                (values
                    (for/list ([var vars*] [vtype var-types]) (cons var (sample-random vtype)))
                    (use-precond))]
              [(or (equal? range-table #f) (equal? range-table (make-hash)))  ; failed range table
                (sample-by-rejection precond vars* evaltor type)]
              [else     
                (values                                                       ; else, valid range table
                    (for/list ([var vars*] [vtype var-types])
                        (cons var (sample-float (dict-ref range-table var (list (make-interval -inf.0 +inf.0))) vtype)))
                    #t)]))

          ; Evaluate with reference interpreter
          (define ctx*
            (for/list ([entry ctx] [type var-types])
              (define evaltor* (get-evaluator (expand-prec type) rnd-mode))
              (set-evaluator-params! evaltor*)
              (cons (car entry) ((evaluator-real evaltor*) (cdr entry)))))
          (set-evaluator-params! evaltor)    
          (define result
            ((eval-fuel-expr evaltor
                             (if precond-met (fuel-good-input) (fuel-bad-input))
                             'timeout)
              body ctx*))
          (define out
            (match result
              [(? gfl?) result]
              [(? complex?) +nan.gfl]
              ['timeout 'timeout]
              [(? boolean?) result]))
          (when (equal? out 'timeout)
            (set! timeout (+ timeout 1)))

          ; evaluate with language
          (define out*
            (if (equal? out 'timeout) 
                (cons 'timeout "")
                (let ([out* (run-test exec-name ctx* type i)])
                  (if (equal? (car out*) 'timeout)
                      (begin
                        (set! timeout (+ timeout 1))
                        (cons 'timeout ""))
                      out*))))
          (when (equal? (tester-name (*tester*)) "wls")
            (when (and (not (equal? out 'timeout)) 
                       (not (value-nan? out))
                       (value-nan? (car out*)))
              (set! nans (+ nans 1))))
          (list ctx* out out*))))

    (unless (null? results) ; display results
      (define successful 
        (for/fold ([success 0]) ([result results] [ignore? (*ignore-by-run*)])
          (if (=* (second result) (car (third result)) type ignore?)
            (add1 success)
            success)))
      (define result-len (length results))
      (unless (and (quiet) (equal? successful result-len))
        (printf "~a/~a: ~a~a~a\n" successful result-len
          (dict-ref props ':name body) 
          (match timeout
            [0 ""]
            [1 " (1 timeout)"]
            [_ (format " (~a timeouts)" timeout)])
          (match nans
            [0 ""]
            [1 " (1 nan)"]
            [_ (format " (~a nans)" nans)])))
      (set! err (+ err (- result-len successful)))
      (set! ignored (+ ignored (for/sum ([ignore? (*ignore-by-run*)]) (if ignore? 1 0))))
      (for ([i (in-naturals 1)] [x (in-list results)] [ignore? (*ignore-by-run*)])
        (define test-passed (=* (second x) (car (third x)) type ignore?))
        (unless (and (not (verbose)) test-passed)
          (printf "\t~a\t~a\t(Expected) ~a\t(Output) ~a\t(Args) ~a\n" 
                  i (if test-passed "Pass" "Fail") (second x)                          
                  (format-output (if (exact-out) (cdr (third x)) (car (third x))))
                  (string-join (map (λ (p) (format-args (car p) (cdr p) type)) (first x)) ", ")))))))
  (unless (zero? ignored)
    (printf "Ignored: ~a\n" ignored))
  (cond
   [(and (suppress-failures) (> err 0))
      (printf "Suppressing failures. Total failed: ~a\n" err)
      0]
   [else err])))
